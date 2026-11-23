`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// capture_v1_0 : AXI4-Lite camera frame capture / downsample IP
//
//  Camera side (pclk domain)
//    Taps the write port of the camera frame BRAM (camera_to_RAM output):
//      pix_we   : 1-cycle write strobe per pixel
//      pix_addr : 0 .. 130559, row-major, 480 pixels per line, reset to 0 each frame
//      pix_data : 16-bit pixel, R = [4:0], G = [10:5], B = [15:11]  (same as TFT)
//    On a capture request, the next full frame (starting at pix_addr == 0) is
//    center-cropped to 256 x 256 (x = 112..367, y = 8..263) and 2x2 averaged
//    into a 128 x 128 RGB888 image.
//
//  AXI4-Lite slave (s00_axi_aclk domain), 17-bit address (128 KB)
//    0x00000 CTRL   W : bit0 = 1 -> start capture of the next frame
//                   R : bit0 = done, bit1 = busy, [31:16] = capture count
//    0x00004 ID     R : 0xCA910002
//    0x00008 INFO   R : {16'd128 (width), 16'd128 (height)}
//    0x10000 + 4*i  R : pixel i (0..16383, row-major) = {8'h00, R8, G8, B8}
//------------------------------------------------------------------------------
module capture_v1_0 #(
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 17
)(
    // camera pixel stream
    input  wire                                 pclk,
    input  wire                                 pix_we,
    input  wire [16:0]                          pix_addr,
    input  wire [15:0]                          pix_data,

    // AXI4-Lite slave
    input  wire                                 s00_axi_aclk,
    input  wire                                 s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]      s00_axi_awaddr,
    input  wire [2:0]                           s00_axi_awprot,
    input  wire                                 s00_axi_awvalid,
    output reg                                  s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0]      s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1:0]  s00_axi_wstrb,
    input  wire                                 s00_axi_wvalid,
    output reg                                  s00_axi_wready,
    output wire [1:0]                           s00_axi_bresp,
    output reg                                  s00_axi_bvalid,
    input  wire                                 s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]      s00_axi_araddr,
    input  wire [2:0]                           s00_axi_arprot,
    input  wire                                 s00_axi_arvalid,
    output reg                                  s00_axi_arready,
    output reg  [C_S00_AXI_DATA_WIDTH-1:0]      s00_axi_rdata,
    output wire [1:0]                           s00_axi_rresp,
    output reg                                  s00_axi_rvalid,
    input  wire                                 s00_axi_rready
);

    localparam LINE_W  = 480;
    localparam X0      = 112;   // crop start x  (480-256)/2
    localparam X1      = 367;   // crop end   x
    localparam Y0      = 8;     // crop start y  (272-256)/2
    localparam Y1      = 263;   // crop end   y
    localparam OUT_W   = 128;

    wire aclk  = s00_axi_aclk;
    wire arstn = s00_axi_aresetn;

    assign s00_axi_bresp = 2'b00;
    assign s00_axi_rresp = 2'b00;

    //==========================================================================
    // result memory : 16384 x 24, written in pclk domain, read in aclk domain
    //==========================================================================
    (* ram_style = "block" *) reg [23:0] img_mem [0:16383];
    reg        mem_we;
    reg [13:0] mem_waddr;
    reg [23:0] mem_wdata;
    always @(posedge pclk) begin
        if (mem_we) img_mem[mem_waddr] <= mem_wdata;
    end

    reg [13:0] mem_raddr;
    reg [23:0] mem_rdata;
    always @(posedge aclk) begin
        mem_rdata <= img_mem[mem_raddr];
    end

    //==========================================================================
    // AXI domain : control registers
    //==========================================================================
    reg        start_tog;          // toggles on each start request
    reg        start_wr;
    reg [15:0] cap_count;
    reg  [2:0] done_sync, busy_sync;
    reg        done_prev;
    reg        done_axi;           // cleared on start write, set when capture finishes

    wire wr_is_ctrl = (s00_axi_awaddr[16] == 1'b0) && (s00_axi_awaddr[15:2] == 14'd0);

    // write channel
    always @(posedge aclk) begin
        if (!arstn) begin
            s00_axi_awready <= 1'b0;
            s00_axi_wready  <= 1'b0;
            s00_axi_bvalid  <= 1'b0;
            start_tog       <= 1'b0;
            start_wr        <= 1'b0;
        end else begin
            if (!s00_axi_awready && s00_axi_awvalid && s00_axi_wvalid && !s00_axi_bvalid) begin
                s00_axi_awready <= 1'b1;
                s00_axi_wready  <= 1'b1;
                s00_axi_bvalid  <= 1'b1;
                if (wr_is_ctrl && s00_axi_wdata[0])
                    start_tog <= ~start_tog;
                start_wr <= (wr_is_ctrl && s00_axi_wdata[0]);
            end else begin
                start_wr        <= 1'b0;
                s00_axi_awready <= 1'b0;
                s00_axi_wready  <= 1'b0;
                if (s00_axi_bvalid && s00_axi_bready)
                    s00_axi_bvalid <= 1'b0;
            end
        end
    end

    // read channel (memory needs 2 cycles: address register -> BRAM output)
    reg  [1:0] rd_stage;
    reg [16:0] rd_addr;
    always @(posedge aclk) begin
        if (!arstn) begin
            s00_axi_arready <= 1'b0;
            s00_axi_rvalid  <= 1'b0;
            s00_axi_rdata   <= 32'd0;
            rd_stage        <= 2'd0;
            rd_addr         <= 17'd0;
            mem_raddr       <= 14'd0;
        end else begin
            s00_axi_arready <= 1'b0;
            if (rd_stage == 2'd0 && !s00_axi_rvalid && s00_axi_arvalid && !s00_axi_arready) begin
                s00_axi_arready <= 1'b1;
                rd_addr         <= s00_axi_araddr;
                mem_raddr       <= s00_axi_araddr[15:2];
                rd_stage        <= 2'd1;
            end else if (rd_stage == 2'd1) begin
                rd_stage <= 2'd2;          // BRAM is reading img_mem[mem_raddr]
            end else if (rd_stage == 2'd2) begin
                rd_stage       <= 2'd0;
                s00_axi_rvalid <= 1'b1;
                if (rd_addr[16])
                    s00_axi_rdata <= {8'h00, mem_rdata};
                else case (rd_addr[15:2])
                    14'd0:   s00_axi_rdata <= {cap_count, 14'd0, busy_sync[2], done_axi};
                    14'd1:   s00_axi_rdata <= 32'hCA910002;
                    14'd2:   s00_axi_rdata <= {16'd128, 16'd128};
                    default: s00_axi_rdata <= 32'd0;
                endcase
            end else if (s00_axi_rvalid && s00_axi_rready) begin
                s00_axi_rvalid <= 1'b0;
            end
        end
    end

    //==========================================================================
    // pclk domain : capture + 2x2 downsample of the center 256x256
    //==========================================================================
    reg  [2:0] rst_sync;
    always @(posedge pclk) rst_sync <= {rst_sync[1:0], arstn};
    wire prst = ~rst_sync[2];

    reg  [2:0] start_sync;
    always @(posedge pclk) start_sync <= {start_sync[1:0], start_tog};
    wire start_pulse = start_sync[2] ^ start_sync[1];

    reg        armed, capturing, done_p;
    reg  [8:0] x;            // 0..479
    reg  [8:0] y;            // 0..271

    // 2x2 sums for the current 2-line band (128 columns) and a shadow copy
    reg  [6:0] acc_r [0:OUT_W-1];   // 4 x 31 = 124
    reg  [7:0] acc_g [0:OUT_W-1];   // 4 x 63 = 252
    reg  [6:0] acc_b [0:OUT_W-1];
    reg  [6:0] sh_r  [0:OUT_W-1];
    reg  [7:0] sh_g  [0:OUT_W-1];
    reg  [6:0] sh_b  [0:OUT_W-1];

    reg        band_end;     // set on the last pixel of a band line, handled in hblank
    reg        dumping;
    reg  [6:0] dump_i;
    reg  [6:0] dump_band;
    reg  [6:0] cur_band;

    wire [4:0] pr = pix_data[4:0];
    wire [5:0] pg = pix_data[10:5];
    wire [4:0] pb = pix_data[15:11];

    wire take_pixel = pix_we && (capturing || (armed && pix_addr == 17'd0));

    // current pixel position inside the crop
    wire       in_crop = (x >= X0) && (x <= X1) && (y >= Y0) && (y <= Y1);
    wire [8:0] ox9     = x - X0;
    wire [6:0] ox      = ox9[7:1];                  // output column 0..127

    // 2x2 sum -> 8 bit:  R,B: sum*255/124 ~ sum*263>>7     G: sum*255/252 ~ sum*259>>8
    wire  [6:0] d_r = sh_r[dump_i];
    wire  [7:0] d_g = sh_g[dump_i];
    wire  [6:0] d_b = sh_b[dump_i];
    wire [15:0] m_r = d_r * 9'd263;
    wire [16:0] m_g = d_g * 9'd259;
    wire [15:0] m_b = d_b * 9'd263;
    wire  [8:0] s_r = m_r[15:7];
    wire  [8:0] s_g = m_g[16:8];
    wire  [8:0] s_b = m_b[15:7];
    wire  [7:0] o_r = s_r[8] ? 8'd255 : s_r[7:0];
    wire  [7:0] o_g = s_g[8] ? 8'd255 : s_g[7:0];
    wire  [7:0] o_b = s_b[8] ? 8'd255 : s_b[7:0];

    integer i;
    always @(posedge pclk) begin
        mem_we <= 1'b0;
        if (prst) begin
            armed <= 1'b0; capturing <= 1'b0; done_p <= 1'b0;
            x <= 9'd0; y <= 9'd0;
            band_end <= 1'b0;
            dumping <= 1'b0; dump_i <= 7'd0; dump_band <= 7'd0; cur_band <= 7'd0;
            for (i = 0; i < OUT_W; i = i + 1) begin
                acc_r[i] <= 7'd0; acc_g[i] <= 8'd0; acc_b[i] <= 7'd0;
            end
        end else begin
            //------------------------------------------------ start request
            if (start_pulse) begin
                armed  <= 1'b1;
                done_p <= 1'b0;
            end

            //------------------------------------------------ pixel accumulate
            if (take_pixel) begin
                if (!capturing) begin
                    // first pixel of the captured frame is (0,0): outside the crop
                    capturing <= 1'b1;
                    armed     <= 1'b0;
                    cur_band  <= 7'd0;
                    for (i = 0; i < OUT_W; i = i + 1) begin
                        acc_r[i] <= 7'd0; acc_g[i] <= 8'd0; acc_b[i] <= 7'd0;
                    end
                    x <= 9'd1; y <= 9'd0;
                end else if (y <= Y1) begin
                    if (in_crop) begin
                        acc_r[ox] <= acc_r[ox] + pr;
                        acc_g[ox] <= acc_g[ox] + pg;
                        acc_b[ox] <= acc_b[ox] + pb;
                    end
                    if (x == LINE_W - 1) begin
                        x <= 9'd0;
                        y <= y + 9'd1;
                        // second line of a 2-line band inside the crop: y = 9, 11, ..., 263
                        if (y >= Y0 && y[0] == 1'b1)
                            band_end <= 1'b1;
                    end else begin
                        x <= x + 9'd1;
                    end
                end
            end

            //------------------------------------------------ band end : copy + clear
            // the band ends at the end of a line -> next cycles are hblank
            if (band_end && !take_pixel) begin
                band_end <= 1'b0;
                for (i = 0; i < OUT_W; i = i + 1) begin
                    sh_r[i] <= acc_r[i]; sh_g[i] <= acc_g[i]; sh_b[i] <= acc_b[i];
                    acc_r[i] <= 7'd0;    acc_g[i] <= 8'd0;    acc_b[i] <= 7'd0;
                end
                dumping   <= 1'b1;
                dump_i    <= 7'd0;
                dump_band <= cur_band;
                cur_band  <= cur_band + 7'd1;
            end

            //------------------------------------------------ dump 128 pixels to memory
            if (dumping) begin
                mem_we    <= 1'b1;
                mem_waddr <= {dump_band, dump_i};
                mem_wdata <= {o_r, o_g, o_b};
                if (dump_i == 7'd127) begin
                    dumping <= 1'b0;
                    if (dump_band == 7'd127) begin
                        capturing <= 1'b0;
                        done_p    <= 1'b1;
                    end
                end else begin
                    dump_i <= dump_i + 7'd1;
                end
            end
        end
    end

    //==========================================================================
    // status back to the AXI domain
    //==========================================================================
    always @(posedge aclk) begin
        if (!arstn) begin
            done_sync <= 3'd0; busy_sync <= 3'd0; done_prev <= 1'b0; cap_count <= 16'd0;
            done_axi  <= 1'b0;
        end else begin
            done_sync <= {done_sync[1:0], done_p};
            busy_sync <= {busy_sync[1:0], (armed | capturing)};
            done_prev <= done_sync[2];
            if (start_wr)                         done_axi <= 1'b0;
            else if (done_sync[2] && !done_prev)  done_axi <= 1'b1;
            if (done_sync[2] && !done_prev) cap_count <= cap_count + 16'd1;
        end
    end

endmodule
