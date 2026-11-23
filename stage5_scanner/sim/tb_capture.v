`timescale 1ns / 1ps
// Testbench: synthetic 480x272 frame -> capture IP -> read 128x128 back over AXI.
// Pattern (constant over every 2x2 block of the center crop):
//   R5 = (x>>3)&31 , G6 = (y>>2)&63 , B5 = 31 - ((x>>3)&31)
module tb_capture;
    reg pclk = 0, aclk = 0, aresetn = 0;
    always #20.8 pclk = ~pclk;   // ~24 MHz
    always #5    aclk = ~aclk;   // 100 MHz

    reg         pix_we = 0;
    reg  [16:0] pix_addr = 0;
    reg  [15:0] pix_data = 0;

    reg  [16:0] awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    capture_v1_0 dut(
        .pclk(pclk), .pix_we(pix_we), .pix_addr(pix_addr), .pix_data(pix_data),
        .s00_axi_aclk(aclk), .s00_axi_aresetn(aresetn),
        .s00_axi_awaddr(awaddr), .s00_axi_awprot(3'b0), .s00_axi_awvalid(awvalid), .s00_axi_awready(awready),
        .s00_axi_wdata(wdata), .s00_axi_wstrb(4'hF), .s00_axi_wvalid(wvalid), .s00_axi_wready(wready),
        .s00_axi_bresp(bresp), .s00_axi_bvalid(bvalid), .s00_axi_bready(bready),
        .s00_axi_araddr(araddr), .s00_axi_arprot(3'b0), .s00_axi_arvalid(arvalid), .s00_axi_arready(arready),
        .s00_axi_rdata(rdata), .s00_axi_rresp(rresp), .s00_axi_rvalid(rvalid), .s00_axi_rready(rready));

    task axi_write(input [16:0] a, input [31:0] d);
    begin
        @(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        @(posedge aclk); while (!awready) @(posedge aclk);
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge aclk);
        @(posedge aclk);
    end endtask

    reg [31:0] rd;
    task axi_read(input [16:0] a);
    begin
        @(posedge aclk); araddr <= a; arvalid <= 1;
        @(posedge aclk); while (!arready) @(posedge aclk);
        arvalid <= 0;
        while (!rvalid) @(posedge aclk);
        rd = rdata;
        @(posedge aclk);
    end endtask

    // one camera frame: 272 lines x 480 px, we every 2nd pclk, hblank 200 clk
    task send_frame;
        integer xx, yy, a;
        reg [4:0] r, b; reg [5:0] g;
    begin
        a = 0;
        for (yy = 0; yy < 272; yy = yy + 1) begin
            for (xx = 0; xx < 480; xx = xx + 1) begin
                r = (xx >> 3) & 31; g = (yy >> 2) & 63; b = 31 - ((xx >> 3) & 31);
                @(posedge pclk); pix_we <= 1; pix_addr <= a; pix_data <= {b, g, r};
                @(posedge pclk); pix_we <= 0; pix_addr <= 0;
                a = a + 1;
            end
            repeat (200) @(posedge pclk);
        end
        repeat (2000) @(posedge pclk);   // vblank
    end endtask

    integer k, errs, ox, oy, px, py, vr, vg, vb, tr, tg, tb2;
    reg [7:0] er, eg, eb, gr, gg, gb;
    initial begin
        errs = 0;
        repeat (20) @(posedge aclk); aresetn = 1;
        repeat (20) @(posedge pclk);

        axi_read(17'h00004); $display("ID     = %h", rd);
        axi_read(17'h00008); $display("INFO   = %h", rd);
        axi_read(17'h00000); $display("CTRL before = %h", rd);

        // a frame passes before the request (must be ignored)
        fork send_frame; join
        axi_write(17'h00000, 32'h1);
        axi_read(17'h00000); $display("CTRL after start = %h (busy expected)", rd);
        send_frame;                      // this frame is captured
        repeat (50) @(posedge aclk);
        axi_read(17'h00000); $display("CTRL after frame = %h (done expected)", rd);

        for (k = 0; k < 16384; k = k + 1) begin
            axi_read(17'h10000 + 4*k);
            ox = k % 128; oy = k / 128;
            px = 112 + 2*ox; py = 8 + 2*oy;          // top-left of the 2x2 block
            vr = (px >> 3) & 31; vg = (py >> 2) & 63; vb = 31 - ((px >> 3) & 31);
            tr = ((4*vr) * 263) >> 7; tg = ((4*vg) * 259) >> 8; tb2 = ((4*vb) * 263) >> 7;
            er = (tr > 255) ? 255 : tr; eg = (tg > 255) ? 255 : tg; eb = (tb2 > 255) ? 255 : tb2;
            gr = rd[23:16]; gg = rd[15:8]; gb = rd[7:0];
            if (gr !== er || gg !== eg || gb !== eb) begin
                errs = errs + 1;
                if (errs < 10) $display("MISMATCH px %0d (ox=%0d oy=%0d): got %h %h %h exp %h %h %h", k, ox, oy, gr, gg, gb, er, eg, eb);
            end
            if (k == 0 || k == 127 || k == 128 || k == 8256 || k == 16383)
                $display("px %5d = R %3d G %3d B %3d", k, gr, gg, gb);
        end
        $display("RESULT: %0d mismatches out of 16384", errs);

        // second capture works too
        axi_write(17'h00000, 32'h1);
        send_frame;
        repeat (50) @(posedge aclk);
        axi_read(17'h00000); $display("CTRL after 2nd = %h (count=2, done)", rd);
        $finish;
    end
endmodule
