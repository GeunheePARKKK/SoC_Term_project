`timescale 1ns / 1ps
// Testbench: objdet  -  learn a white background, then a frame with a dark
// rectangle at x=100..179, y=60..139  ->  expected box (8x8 block grid):
// x0 = 96, x1 = 183, y0 = 56, y1 = 143
module tb_objdet;
    reg pclk = 0, aclk = 0, aresetn = 0;
    always #20.8 pclk = ~pclk;
    always #5    aclk = ~aclk;

    reg         pix_we = 0;
    reg  [16:0] pix_addr = 0;
    reg  [15:0] pix_data = 0;

    reg  [7:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid, present;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;
    wire        box_en, box_tog;
    wire [8:0]  box_x0, box_x1, box_y0, box_y1;
    wire [15:0] box_color;

    objdet_v1_0 dut(
        .pclk(pclk), .pix_we(pix_we), .pix_addr(pix_addr), .pix_data(pix_data),
        .box_en(box_en), .box_x0(box_x0), .box_x1(box_x1), .box_y0(box_y0), .box_y1(box_y1),
        .box_color(box_color), .box_tog(box_tog), .obj_present(present),
        .s00_axi_aclk(aclk), .s00_axi_aresetn(aresetn),
        .s00_axi_awaddr(awaddr), .s00_axi_awprot(3'b0), .s00_axi_awvalid(awvalid), .s00_axi_awready(awready),
        .s00_axi_wdata(wdata), .s00_axi_wstrb(4'hF), .s00_axi_wvalid(wvalid), .s00_axi_wready(wready),
        .s00_axi_bresp(bresp), .s00_axi_bvalid(bvalid), .s00_axi_bready(bready),
        .s00_axi_araddr(araddr), .s00_axi_arprot(3'b0), .s00_axi_arvalid(arvalid), .s00_axi_arready(arready),
        .s00_axi_rdata(rdata), .s00_axi_rresp(rresp), .s00_axi_rvalid(rvalid), .s00_axi_rready(rready));

    task axi_write(input [7:0] a, input [31:0] d);
    begin
        @(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        @(posedge aclk); while (!awready) @(posedge aclk);
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge aclk);
        @(posedge aclk);
    end endtask
    reg [31:0] rd;
    task axi_read(input [7:0] a);
    begin
        @(posedge aclk); araddr <= a; arvalid <= 1;
        @(posedge aclk); while (!arready) @(posedge aclk);
        arvalid <= 0;
        while (!rvalid) @(posedge aclk);
        rd = rdata; @(posedge aclk);
    end endtask

    // white = R31 G63 B31 ; object = dark gray R4 G8 B4 ; small noise on white
    task send_frame(input obj);
        integer xx, yy, a; reg [4:0] r, b; reg [5:0] g;
    begin
        a = 0;
        for (yy = 0; yy < 272; yy = yy + 1) begin
            for (xx = 0; xx < 480; xx = xx + 1) begin
                r = 31 - ((xx + yy) % 2); g = 63 - (xx % 3); b = 30;
                if (obj && xx >= 100 && xx <= 179 && yy >= 60 && yy <= 139) begin r = 4; g = 8; b = 4; end
                @(posedge pclk); pix_we <= 1; pix_addr <= a; pix_data <= {b, g, r};
                @(posedge pclk); pix_we <= 0; pix_addr <= 0;
                a = a + 1;
            end
            repeat (200) @(posedge pclk);
        end
        repeat (2000) @(posedge pclk);
    end endtask

    initial begin
        repeat (20) @(posedge aclk); aresetn = 1;
        repeat (20) @(posedge pclk);
        axi_read(8'h20); $display("ID      = %h", rd);
        axi_read(8'h00); $display("CTRL    = %h (enable,auto = 1,1)", rd);

        axi_write(8'h00, 32'h7);                 // learn + enable + auto
        send_frame(0);                           // learned as background
        axi_read(8'h04); $display("STATUS after learn  = %h (bgvalid=1, present=0)", rd);

        send_frame(0);                           // empty again
        axi_read(8'h04); $display("STATUS empty        = %h (present=0)", rd);
        axi_read(8'h18); $display("COUNT  empty        = %0d", rd);
        $display("box_en empty = %b", box_en);

        send_frame(1);                           // with object
        axi_read(8'h04); $display("STATUS object       = %h (present=1)", rd);
        axi_read(8'h18); $display("COUNT  object       = %0d (expect ~110 blocks)", rd);
        axi_read(8'h10); $display("BOX_X  = %0d .. %0d (expect 96 .. 183)", rd[15:0], rd[31:16]);
        axi_read(8'h14); $display("BOX_Y  = %0d .. %0d (expect 56 .. 143)", rd[15:0], rd[31:16]);
        $display("box outputs: en=%b x %0d..%0d y %0d..%0d color %h", box_en, box_x0, box_x1, box_y0, box_y1, box_color);

        axi_write(8'h1C, 32'h001F);              // red
        send_frame(1);
        $display("after color write: color %h (expect 001f)", box_color);

        send_frame(0);
        axi_read(8'h04); $display("STATUS removed      = %h (present=0)", rd);
        $display("box_en removed = %b (expect 0, auto mode)", box_en);
        $finish;
    end
endmodule
