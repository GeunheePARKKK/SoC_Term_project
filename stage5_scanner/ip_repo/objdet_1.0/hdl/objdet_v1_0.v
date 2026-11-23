`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// objdet_v1_0 : AXI4-Lite object detector (background subtraction + bounding box)
//
//  Camera side (pclk domain), every frame:
//    - pixels (480 x 272, RGB565 with R=[4:0], G=[10:5], B=[15:11]) are averaged
//      into 8 x 8 blocks  ->  60 x 34 = 2040 blocks
//    - each block average (8-bit R,G,B) is compared with a stored background
//      block: diff = |dR| + |dG| + |dB|;  diff > THRESH  -> "changed" block
//    - bounding box of all changed blocks, and their count
//    - object present = background valid && count >= MINBLK
//    - LEARN: the next whole frame is written as the new background
//
//  Box outputs (to the TFT overlay, quasi-static, updated once per frame):
//    box_en, box_x0/x1/y0/y1 (pixel coords 0..479 / 0..271), box_color, box_tog
//    box_tog toggles every time new box values are latched (for CDC)
//
//  AXI4-Lite slave registers (8-bit address)
//    0x00 CTRL    RW : bit0 = 1 -> learn background (write-1, self clearing)
//                      bit1 = overlay enable   (reset 1)
//                      bit2 = auto: draw only while an object is present (reset 1)
//    0x04 STATUS  R  : bit0 present, bit1 background valid, bit2 learning,
//                      [31:16] processed frame count
//    0x08 THRESH  RW : block difference threshold (reset 60)
//    0x0C MINBLK  RW : changed blocks needed for "present" (reset 3)
//    0x10 BOX_X   R  : {x1[15:0], x0[15:0]}
//    0x14 BOX_Y   R  : {y1[15:0], y0[15:0]}
//    0x18 COUNT   R  : changed blocks in the last frame
//    0x1C COLOR   RW : box color in TFT RGB565 (R=[4:0],G=[10:5],B=[15:11]), reset green 0x07E0
//    0x20 ID      R  : 0x0BDE0001
//------------------------------------------------------------------------------
module objdet_v1_0 #(
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 8
)(
    // camera pixel stream
    input  wire                                 pclk,
    input  wire                                 pix_we,
    input  wire [16:0]                          pix_addr,
    input  wire [15:0]                          pix_data,

    // box to the TFT overlay
    output reg                                  box_en,
    output reg  [8:0]                           box_x0,
    output reg  [8:0]                           box_x1,
    output reg  [8:0]                           box_y0,
    output reg  [8:0]                           box_y1,
    output reg  [15:0]                          box_color,
    output reg                                  box_tog,

    // object present (level, pclk domain) - for an interrupt later
    output wire                                 obj_present,

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
    localparam N_BX    = 60;    // 480 / 8
    localparam N_BY    = 34;    // 272 / 8

    wire aclk  = s00_axi_aclk;
    wire arstn = s00_axi_aresetn;
    assign s00_axi_bresp = 2'b00;
    assign s00_axi_rresp = 2'b00;

    //==========================================================================
    // AXI domain registers
    //==========================================================================
    reg        learn_tog;
    reg        cfg_enable, cfg_auto;
    reg [15:0] cfg_thresh;
    reg  [7:0] cfg_minblk;
    reg [15:0] cfg_color;

    // status from the pclk domain (quasi-static, double registered)
    reg        st_present, st_bgvalid, st_learning;
    reg [15:0] st_frames;
    reg  [8:0] st_x0, st_x1, st_y0, st_y1;
    reg [11:0] st_count;

    wire [5:0] wa = s00_axi_awaddr[7:2];
    wire [5:0] ra = s00_axi_araddr[7:2];

    always @(posedge aclk) begin
        if (!arstn) begin
            s00_axi_awready <= 1'b0; s00_axi_wready <= 1'b0; s00_axi_bvalid <= 1'b0;
            learn_tog  <= 1'b0;
            cfg_enable <= 1'b1; cfg_auto <= 1'b1;
            cfg_thresh <= 16'd60; cfg_minblk <= 8'd3; cfg_color <= 16'h07E0;
        end else begin
            if (!s00_axi_awready && s00_axi_awvalid && s00_axi_wvalid && !s00_axi_bvalid) begin
                s00_axi_awready <= 1'b1; s00_axi_wready <= 1'b1; s00_axi_bvalid <= 1'b1;
                case (wa)
                    6'd0: begin
                        if (s00_axi_wdata[0]) learn_tog <= ~learn_tog;
                        cfg_enable <= s00_axi_wdata[1];
                        cfg_auto   <= s00_axi_wdata[2];
                    end
                    6'd2: cfg_thresh <= s00_axi_wdata[15:0];
                    6'd3: cfg_minblk <= s00_axi_wdata[7:0];
                    6'd7: cfg_color  <= s00_axi_wdata[15:0];
                    default: ;
                endcase
            end else begin
                s00_axi_awready <= 1'b0; s00_axi_wready <= 1'b0;
                if (s00_axi_bvalid && s00_axi_bready) s00_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!arstn) begin
            s00_axi_arready <= 1'b0; s00_axi_rvalid <= 1'b0; s00_axi_rdata <= 32'd0;
        end else begin
            if (!s00_axi_arready && s00_axi_arvalid && !s00_axi_rvalid) begin
                s00_axi_arready <= 1'b1;
                s00_axi_rvalid  <= 1'b1;
                case (ra)
                    6'd0: s00_axi_rdata <= {29'd0, cfg_auto, cfg_enable, 1'b0};
                    6'd1: s00_axi_rdata <= {st_frames, 13'd0, st_learning, st_bgvalid, st_present};
                    6'd2: s00_axi_rdata <= {16'd0, cfg_thresh};
                    6'd3: s00_axi_rdata <= {24'd0, cfg_minblk};
                    6'd4: s00_axi_rdata <= {7'd0, st_x1, 7'd0, st_x0};
                    6'd5: s00_axi_rdata <= {7'd0, st_y1, 7'd0, st_y0};
                    6'd6: s00_axi_rdata <= {20'd0, st_count};
                    6'd7: s00_axi_rdata <= {16'd0, cfg_color};
                    6'd8: s00_axi_rdata <= 32'h0BDE0001;
                    default: s00_axi_rdata <= 32'd0;
                endcase
            end else begin
                s00_axi_arready <= 1'b0;
                if (s00_axi_rvalid && s00_axi_rready) s00_axi_rvalid <= 1'b0;
            end
        end
    end

    //==========================================================================
    // pclk domain
    //==========================================================================
    reg [2:0] rst_sync;
    always @(posedge pclk) rst_sync <= {rst_sync[1:0], arstn};
    wire prst = ~rst_sync[2];

    reg [2:0] learn_sync;
    always @(posedge pclk) learn_sync <= {learn_sync[1:0], learn_tog};
    wire learn_pulse = learn_sync[2] ^ learn_sync[1];

    // configuration (changes rarely; double registered)
    reg [15:0] p_thresh_m, p_thresh;
    reg  [7:0] p_minblk_m, p_minblk;
    reg [15:0] p_color_m,  p_color;
    reg  [1:0] p_en_m, p_en;              // {auto, enable}
    always @(posedge pclk) begin
        p_thresh_m <= cfg_thresh; p_thresh <= p_thresh_m;
        p_minblk_m <= cfg_minblk; p_minblk <= p_minblk_m;
        p_color_m  <= cfg_color;  p_color  <= p_color_m;
        p_en_m     <= {cfg_auto, cfg_enable}; p_en <= p_en_m;
    end

    // background memory : 2040 x 24 (R8,G8,B8)
    (* ram_style = "block" *) reg [23:0] bg_mem [0:2047];
    reg        bg_we;
    reg [10:0] bg_waddr, bg_raddr;
    reg [23:0] bg_wdata, bg_q;
    always @(posedge pclk) begin
        if (bg_we) bg_mem[bg_waddr] <= bg_wdata;
        bg_q <= bg_mem[bg_raddr];
    end

    // pixel position
    reg  [8:0] x, y;
    wire       first = (pix_addr == 17'd0);
    wire [8:0] cx = first ? 9'd0 : x;
    wire [8:0] cy = first ? 9'd0 : y;
    wire [5:0] bx = cx[8:3];

    wire [4:0] pr = pix_data[4:0];
    wire [5:0] pg = pix_data[10:5];
    wire [4:0] pb = pix_data[15:11];

    // per-band accumulators (64 pixels per block) and shadow copy
    reg [10:0] acc_r [0:N_BX-1];   // 64 x 31 = 1984
    reg [11:0] acc_g [0:N_BX-1];   // 64 x 63 = 4032
    reg [10:0] acc_b [0:N_BX-1];
    reg [10:0] sh_r  [0:N_BX-1];
    reg [11:0] sh_g  [0:N_BX-1];
    reg [10:0] sh_b  [0:N_BX-1];

    reg        band_end;
    reg  [5:0] band_y;                     // band (block row) that just ended

    // block processing FSM
    reg  [1:0] pst;                        // 0 idle, 1 read issued, 2 compare
    reg  [5:0] pi;                         // block column 0..59
    reg  [5:0] pband;
    reg [10:0] pband_base;                 // pband * 60

    // frame state
    reg        learn_pending, learning, bg_valid;
    reg  [5:0] minbx, maxbx, minby, maxby;
    reg [11:0] cnt;
    reg        present;
    reg [15:0] frames;
    reg [11:0] last_cnt;

    assign obj_present = present;

    // block average and difference (combinational, pst == 2)
    wire  [7:0] av_r = sh_r[pi][10:3];     // sum/8  : 0..248  (5-bit value * 8)
    wire  [7:0] av_g = sh_g[pi][11:4];     // sum/16 : 0..252  (6-bit value * 4)
    wire  [7:0] av_b = sh_b[pi][10:3];
    wire  [7:0] bg_r = bg_q[23:16];
    wire  [7:0] bg_g = bg_q[15:8];
    wire  [7:0] bg_b = bg_q[7:0];
    wire  [7:0] d_r  = (av_r > bg_r) ? (av_r - bg_r) : (bg_r - av_r);
    wire  [7:0] d_g  = (av_g > bg_g) ? (av_g - bg_g) : (bg_g - av_g);
    wire  [7:0] d_b  = (av_b > bg_b) ? (av_b - bg_b) : (bg_b - av_b);
    wire  [9:0] diff = d_r + d_g + d_b;
    wire        changed = bg_valid && !learning && (diff > p_thresh[9:0]);

    integer i;
    always @(posedge pclk) begin
        bg_we <= 1'b0;
        if (prst) begin
            x <= 9'd0; y <= 9'd0; band_end <= 1'b0; band_y <= 6'd0;
            pst <= 2'd0; pi <= 6'd0; pband <= 6'd0; pband_base <= 11'd0;
            learn_pending <= 1'b0; learning <= 1'b0; bg_valid <= 1'b0;
            minbx <= 6'd63; maxbx <= 6'd0; minby <= 6'd63; maxby <= 6'd0; cnt <= 12'd0;
            present <= 1'b0; frames <= 16'd0; last_cnt <= 12'd0;
            box_en <= 1'b0; box_x0 <= 9'd0; box_x1 <= 9'd0; box_y0 <= 9'd0; box_y1 <= 9'd0;
            box_color <= 16'h07E0; box_tog <= 1'b0;
            for (i = 0; i < N_BX; i = i + 1) begin
                acc_r[i] <= 11'd0; acc_g[i] <= 12'd0; acc_b[i] <= 11'd0;
            end
        end else begin
            if (learn_pulse) learn_pending <= 1'b1;

            //------------------------------------------------ pixels
            if (pix_we) begin
                if (first) begin
                    // new frame: start learning if requested
                    if (learn_pending) begin
                        learning      <= 1'b1;
                        learn_pending <= 1'b0;
                    end
                    for (i = 0; i < N_BX; i = i + 1) begin
                        acc_r[i] <= 11'd0; acc_g[i] <= 12'd0; acc_b[i] <= 11'd0;
                    end
                    acc_r[0] <= pr; acc_g[0] <= pg; acc_b[0] <= pb;
                    x <= 9'd1; y <= 9'd0;
                end else if (y < 9'd272) begin
                    acc_r[bx] <= acc_r[bx] + pr;
                    acc_g[bx] <= acc_g[bx] + pg;
                    acc_b[bx] <= acc_b[bx] + pb;
                    if (x == LINE_W - 1) begin
                        x <= 9'd0;
                        y <= y + 9'd1;
                        if (y[2:0] == 3'd7) begin
                            band_end <= 1'b1;
                            band_y   <= y[8:3];
                        end
                    end else begin
                        x <= x + 9'd1;
                    end
                end
            end

            //------------------------------------------------ band end : copy + clear (hblank)
            if (band_end && !pix_we && pst == 2'd0) begin
                band_end <= 1'b0;
                for (i = 0; i < N_BX; i = i + 1) begin
                    sh_r[i] <= acc_r[i]; sh_g[i] <= acc_g[i]; sh_b[i] <= acc_b[i];
                    acc_r[i] <= 11'd0;   acc_g[i] <= 12'd0;   acc_b[i] <= 11'd0;
                end
                pband      <= band_y;
                pband_base <= {band_y, 6'd0} - {band_y, 2'd0};   // band * 60
                pi         <= 6'd0;
                pst        <= 2'd1;
                bg_raddr   <= {band_y, 6'd0} - {band_y, 2'd0};
            end

            //------------------------------------------------ process 60 blocks of the band
            case (pst)
                2'd1: pst <= 2'd2;                 // bg_q valid next cycle
                2'd2: begin
                    if (learning) begin
                        bg_we    <= 1'b1;
                        bg_waddr <= pband_base + pi;
                        bg_wdata <= {av_r, av_g, av_b};
                    end else if (changed) begin
                        cnt <= cnt + 12'd1;
                        if (pi    < minbx) minbx <= pi;
                        if (pi    > maxbx) maxbx <= pi;
                        if (pband < minby) minby <= pband;
                        if (pband > maxby) maxby <= pband;
                    end
                    if (pi == N_BX - 1) begin
                        pst <= 2'd0;
                        if (pband == N_BY - 1) begin
                            //------------------------ frame complete
                            frames <= frames + 16'd1;
                            if (learning) begin
                                learning <= 1'b0;
                                bg_valid <= 1'b1;
                                present  <= 1'b0;
                                last_cnt <= 12'd0;
                            end else begin
                                present  <= bg_valid && (cnt >= {4'd0, p_minblk});
                                last_cnt <= cnt;
                                if (bg_valid && cnt >= {4'd0, p_minblk}) begin
                                    box_x0 <= {minbx, 3'd0};
                                    box_x1 <= {maxbx, 3'd7};
                                    box_y0 <= {minby, 3'd0};
                                    box_y1 <= {maxby, 3'd7};
                                end
                            end
                            box_en    <= p_en[0] && bg_valid && !learning &&
                                         (!p_en[1] || (cnt >= {4'd0, p_minblk}));
                            box_color <= p_color;
                            box_tog   <= ~box_tog;
                            minbx <= 6'd63; maxbx <= 6'd0; minby <= 6'd63; maxby <= 6'd0;
                            cnt   <= 12'd0;
                        end
                    end else begin
                        pi       <= pi + 6'd1;
                        bg_raddr <= pband_base + pi + 11'd1;
                        pst      <= 2'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    //==========================================================================
    // status to the AXI domain (quasi-static values, 2-stage registers)
    //==========================================================================
    reg        m_present, m_bgvalid, m_learning;
    reg [15:0] m_frames;
    reg  [8:0] m_x0, m_x1, m_y0, m_y1;
    reg [11:0] m_count;
    always @(posedge aclk) begin
        m_present <= present;  m_bgvalid <= bg_valid; m_learning <= learning | learn_pending;
        m_frames  <= frames;   m_count   <= last_cnt;
        m_x0 <= box_x0; m_x1 <= box_x1; m_y0 <= box_y0; m_y1 <= box_y1;
        st_present <= m_present; st_bgvalid <= m_bgvalid; st_learning <= m_learning;
        st_frames  <= m_frames;  st_count   <= m_count;
        st_x0 <= m_x0; st_x1 <= m_x1; st_y0 <= m_y0; st_y1 <= m_y1;
    end

endmodule
