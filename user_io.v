//
// user_io.v
//
// user_io for the MiST board
// http://code.google.com/p/mist-board/
//
// Copyright (c) 2014 Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////

//
// Use buffer to access SD card. It's time-critical part.
// Made module synchroneous with 2 clock domains: clk_sys and SPI_SCK
//                                                           (Sorgelig)
//
// for synchronous projects default value for PS2DIV is fine for any frequency of system clock.
// clk_ps2 = clk_sys/(PS2DIV*2)
//

module user_io #(parameter STRLEN=0, parameter PS2DIV=100)
(

	// parameter STRLEN and the actual length of conf_str have to match
	input [(8*STRLEN)-1:0] conf_str,

	// Global clock. It should be around 100MHz (higher is better).
	input             clk_sys,

	// Global SPI clock from ARM. 24MHz
	input             SPI_SCK,

	input             CONF_DATA0,
	input             SPI_SS2,
	output            SPI_DO,
	input             SPI_DI,

	output reg  [7:0] joystick_0,
	output reg  [7:0] joystick_1,
	output reg [15:0] joystick_analog_0,
	output reg [15:0] joystick_analog_1,
	output      [1:0] buttons,
	output      [1:0] switches,
	output            scandoubler_disable,
	output            ypbpr,

	output reg [31:0] status,

	// SD config
	input             sd_conf,
	input             sd_sdhc,
	output            sd_mounted,  // signaling that new image has been mounted
	output reg [31:0] img_size,    // size of image in bytes

	// SD block level access
	input      [31:0] sd_lba,
	input             sd_rd,
	input             sd_wr,
	output reg        sd_ack,
	output reg        sd_ack_conf,

	// SD byte level access. Signals for 2-PORT altsyncram.
	output reg  [8:0] sd_buff_addr,
	output reg  [7:0] sd_buff_dout,
	input       [7:0] sd_buff_din,
	output reg        sd_buff_wr,

	// ps2 keyboard emulation
	output            ps2_kbd_clk,
	output reg        ps2_kbd_data,
	output            ps2_mouse_clk,
	output reg        ps2_mouse_data,
	input             ps2_caps_led
);

reg [7:0] b_data;
reg [6:0] sbuf;
reg [7:0] cmd;
reg [2:0] bit_cnt;    // counts bits 0-7 0-7 ...
reg [9:0] byte_cnt;   // counts bytes
reg [7:0] but_sw;
reg [2:0] stick_idx;

reg    mount_strobe = 0;
assign sd_mounted   = mount_strobe;

assign buttons = but_sw[1:0];
assign switches = but_sw[3:2];
assign scandoubler_disable = but_sw[4];
assign ypbpr = but_sw[5];

wire [7:0] spi_dout = { sbuf, SPI_DI};

// this variant of user_io is for 8 bit cores (type == a4) only
wire [7:0] core_type = 8'ha4;

// command byte read by the io controller
wire [7:0] sd_cmd = { 4'h5, sd_conf, sd_sdhc, sd_wr, sd_rd };

reg spi_do;
assign SPI_DO = CONF_DATA0 ? 1'bZ : spi_do;

wire [7:0] kbd_led = { 2'b01, 4'b0000, ps2_caps_led, 1'b1};

// drive MISO only when transmitting core id
always@(negedge SPI_SCK) begin
	if(!CONF_DATA0) begin
		// first byte returned is always core type, further bytes are 
		// command dependent
      if(byte_cnt == 0) begin
		  spi_do <= core_type[~bit_cnt];

		end else begin
			case(cmd)
				// reading config string
				8'h14: begin
					// returning a byte from string
						if(byte_cnt < STRLEN + 1) spi_do <= conf_str[{STRLEN - byte_cnt,~bit_cnt}];
							else spi_do <= 0;
					end

				// reading sd card status
				8'h16: begin
						if(byte_cnt == 1) spi_do <= sd_cmd[~bit_cnt];
						else if((byte_cnt >= 2) && (byte_cnt < 6)) spi_do <= sd_lba[{5-byte_cnt, ~bit_cnt}];
						else spi_do <= 0;
					end

				// reading sd card write data
				8'h18:
						spi_do <= b_data[~bit_cnt];

				// reading keyboard LED status
				8'h1f:
						spi_do <= kbd_led[~bit_cnt];

				default:
						spi_do <= 0;
			endcase
		end
   end
end

reg b_wr2,b_wr3;
always @(negedge clk_sys) begin
	b_wr3      <= b_wr2;
	sd_buff_wr <= b_wr3;
end

// SPI receiver
always@(posedge SPI_SCK or posedge CONF_DATA0) begin

	if(CONF_DATA0) begin
		b_wr2 <= 0;
	   bit_cnt <= 0;
	   byte_cnt <= 0;
		sd_ack <= 0;
		sd_ack_conf <= 0;
	end else begin
		b_wr2 <= 0;

		sbuf <= spi_dout[6:0];
		bit_cnt <= bit_cnt + 1'd1;
		if(bit_cnt == 5) begin
			if (byte_cnt == 0) sd_buff_addr <= 0;
			if((byte_cnt != 0) & (sd_buff_addr != 511)) sd_buff_addr <= sd_buff_addr + 1'b1;
			if((byte_cnt == 1) & ((cmd == 8'h17) | (cmd == 8'h19))) sd_buff_addr <= 0;
		end

		// finished reading command byte
      if(bit_cnt == 7) begin
			if(~&byte_cnt) byte_cnt <= byte_cnt + 8'd1;
			if(byte_cnt == 0) begin
				cmd <= spi_dout;

				if(spi_dout == 8'h19) begin
					sd_ack_conf  <= 1;
					sd_buff_addr <= 0;
				end
				if((spi_dout == 8'h17) || (spi_dout == 8'h18)) begin
					sd_ack       <= 1;
					sd_buff_addr <= 0;
				end
				if(spi_dout == 8'h18) b_data <= sd_buff_din;

				mount_strobe <= 0;

			end else begin
			
				case(cmd)
					// buttons and switches
					8'h01: but_sw <= spi_dout; 
					8'h02: joystick_0 <= spi_dout;
					8'h03: joystick_1 <= spi_dout;

					// store incoming ps2 mouse bytes 
					8'h04: begin
							ps2_mouse_fifo[ps2_mouse_wptr] <= spi_dout; 
							ps2_mouse_wptr <= ps2_mouse_wptr + 1'd1;
						end

					// store incoming ps2 keyboard bytes 
					8'h05: begin
							ps2_kbd_fifo[ps2_kbd_wptr] <= spi_dout; 
							ps2_kbd_wptr <= ps2_kbd_wptr + 1'd1;
						end
				
					8'h15: status[7:0] <= spi_dout;
				
					// send SD config IO -> FPGA
					// flag that download begins
					// sd card knows data is config if sd_dout_strobe is asserted
					// with sd_ack still being inactive (low)
					8'h19,
					// send sector IO -> FPGA
					// flag that download begins
					8'h17: begin
							sd_buff_dout <= spi_dout;
							b_wr2 <= 1;
						end

					8'h18: b_data <= sd_buff_din;

					// joystick analog
					8'h1a: begin
							// first byte is joystick index
							if(byte_cnt == 1) stick_idx <= spi_dout[2:0];
							else if(byte_cnt == 2) begin
								// second byte is x axis
								if(stick_idx == 0) joystick_analog_0[15:8] <= spi_dout;
									else if(stick_idx == 1) joystick_analog_1[15:8] <= spi_dout;
							end else if(byte_cnt == 3) begin
								// third byte is y axis
								if(stick_idx == 0) joystick_analog_0[7:0] <= spi_dout;
									else if(stick_idx == 1) joystick_analog_1[7:0] <= spi_dout;
							end
						end

					// notify image selection
					8'h1c: mount_strobe <= 1;

					// send image info
					8'h1d: if(byte_cnt<5) img_size[(byte_cnt-1)<<3 +:8] <= spi_dout;

					// status, 32bit version
					8'h1e: if(byte_cnt<5) status[(byte_cnt-1)<<3 +:8] <= spi_dout;

					default: ;
				endcase
			end
		end
	end
end


///////////////////////////////   PS2   ///////////////////////////////
// 8 byte fifos to store ps2 bytes
localparam PS2_FIFO_BITS = 3;

reg clk_ps2;
always @(negedge clk_sys) begin
	integer cnt;
	cnt <= cnt + 1'd1;
	if(cnt == PS2DIV) begin
		clk_ps2 <= ~clk_ps2;
		cnt <= 0;
	end
end

// keyboard
reg [7:0] ps2_kbd_fifo[1<<PS2_FIFO_BITS];
reg [PS2_FIFO_BITS-1:0] ps2_kbd_wptr;
reg [PS2_FIFO_BITS-1:0] ps2_kbd_rptr;

// ps2 transmitter state machine
reg [3:0] ps2_kbd_tx_state;
reg [7:0] ps2_kbd_tx_byte;
reg ps2_kbd_parity;

assign ps2_kbd_clk = clk_ps2 || (ps2_kbd_tx_state == 0);

// ps2 transmitter
// Takes a byte from the FIFO and sends it in a ps2 compliant serial format.
reg ps2_kbd_r_inc;
always@(posedge clk_sys) begin
	reg old_clk;
	old_clk <= clk_ps2;
	if(~old_clk & clk_ps2) begin
		ps2_kbd_r_inc <= 0;

		if(ps2_kbd_r_inc) ps2_kbd_rptr <= ps2_kbd_rptr + 1'd1;

		// transmitter is idle?
		if(ps2_kbd_tx_state == 0) begin
			// data in fifo present?
			if(ps2_kbd_wptr != ps2_kbd_rptr) begin
				// load tx register from fifo
				ps2_kbd_tx_byte <= ps2_kbd_fifo[ps2_kbd_rptr];
				ps2_kbd_r_inc <= 1;

				// reset parity
				ps2_kbd_parity <= 1;

				// start transmitter
				ps2_kbd_tx_state <= 1;

				// put start bit on data line
				ps2_kbd_data <= 0;			// start bit is 0
			end
		end else begin

			// transmission of 8 data bits
			if((ps2_kbd_tx_state >= 1)&&(ps2_kbd_tx_state < 9)) begin
				ps2_kbd_data <= ps2_kbd_tx_byte[0];	          // data bits
				ps2_kbd_tx_byte[6:0] <= ps2_kbd_tx_byte[7:1]; // shift down
				if(ps2_kbd_tx_byte[0]) 
					ps2_kbd_parity <= !ps2_kbd_parity;
			end

			// transmission of parity
			if(ps2_kbd_tx_state == 9) ps2_kbd_data <= ps2_kbd_parity;

			// transmission of stop bit
			if(ps2_kbd_tx_state == 10) ps2_kbd_data <= 1;    // stop bit is 1

			// advance state machine
			if(ps2_kbd_tx_state < 11) ps2_kbd_tx_state <= ps2_kbd_tx_state + 1'd1;
				else ps2_kbd_tx_state <= 0;
		end
	end
end

// mouse
reg [7:0] ps2_mouse_fifo[1<<PS2_FIFO_BITS];
reg [PS2_FIFO_BITS-1:0] ps2_mouse_wptr;
reg [PS2_FIFO_BITS-1:0] ps2_mouse_rptr;

// ps2 transmitter state machine
reg [3:0] ps2_mouse_tx_state;
reg [7:0] ps2_mouse_tx_byte;
reg ps2_mouse_parity;

assign ps2_mouse_clk = clk_ps2 || (ps2_mouse_tx_state == 0);

// ps2 transmitter
// Takes a byte from the FIFO and sends it in a ps2 compliant serial format.
reg ps2_mouse_r_inc;
always@(posedge clk_sys) begin
	reg old_clk;
	old_clk <= clk_ps2;
	if(~old_clk & clk_ps2) begin
		ps2_mouse_r_inc <= 0;

		if(ps2_mouse_r_inc) ps2_mouse_rptr <= ps2_mouse_rptr + 1'd1;

		// transmitter is idle?
		if(ps2_mouse_tx_state == 0) begin
			// data in fifo present?
			if(ps2_mouse_wptr != ps2_mouse_rptr) begin
				// load tx register from fifo
				ps2_mouse_tx_byte <= ps2_mouse_fifo[ps2_mouse_rptr];
				ps2_mouse_r_inc <= 1;

				// reset parity
				ps2_mouse_parity <= 1;

				// start transmitter
				ps2_mouse_tx_state <= 1;

				// put start bit on data line
				ps2_mouse_data <= 0;			// start bit is 0
			end
		end else begin

			// transmission of 8 data bits
			if((ps2_mouse_tx_state >= 1)&&(ps2_mouse_tx_state < 9)) begin
				ps2_mouse_data <= ps2_mouse_tx_byte[0];			  // data bits
				ps2_mouse_tx_byte[6:0] <= ps2_mouse_tx_byte[7:1]; // shift down
				if(ps2_mouse_tx_byte[0]) 
					ps2_mouse_parity <= !ps2_mouse_parity;
			end

			// transmission of parity
			if(ps2_mouse_tx_state == 9) ps2_mouse_data <= ps2_mouse_parity;

			// transmission of stop bit
			if(ps2_mouse_tx_state == 10) ps2_mouse_data <= 1;	  // stop bit is 1

			// advance state machine
			if(ps2_mouse_tx_state < 11) ps2_mouse_tx_state <= ps2_mouse_tx_state + 1'd1;
				else ps2_mouse_tx_state <= 0;
		end
	end
end

endmodule
