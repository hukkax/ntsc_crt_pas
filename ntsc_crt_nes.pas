{*****************************************************************************
 *
 * NTSC/CRT - Integer-only NTSC video signal encoding / decoding emulation
 *
 * An interface to convert NES PPU output in RGB form to an analog NTSC signal.
 *
 *   by EMMIR 2018-2023
 *   FreePascal port by hukka 2025 with help from muzzy
 *
 *   Github (original): https://github.com/LMP88959/NTSC-CRT
 *   Github (FPC port): https://github.com/hukkax/ntsc_crt_pas
 *   YouTube: https://www.youtube.com/@EMMIR_KC/videos
 *   Discord: https://discord.com/invite/hdYctSmyQJ
 *
 *****************************************************************************}
unit ntsc_crt_nes;

{$I ntsc_crt_options.inc}

interface

uses
	Classes, SysUtils,
	ntsc_crt_common, ntsc_crt_base;

type
	TNTSCCRT_NES = class(TNTSCCRTBase)
	const
		FP_PPUpx   = 9;   // front porch
		SYNC_PPUpx = 25;  // sync tip
		BW_PPUpx   = 4;   // breezeway
		CB_PPUpx   = 15;  // color burst
		BP_PPUpx   = 5;   // back porch
		PS_PPUpx   = 1;   // pulse
		LB_PPUpx   = 15;  // left border
		AV_PPUpx   = 256; // active video
		RB_PPUpx   = 11;  // right border
		HB_PPUpx   = (FP_PPUpx + SYNC_PPUpx + BW_PPUpx + CB_PPUpx + BP_PPUpx); // h blank
		// line duration should be ~63500 ns
		LINE_PPUpx = (FP_PPUpx + SYNC_PPUpx + BW_PPUpx + CB_PPUpx + BP_PPUpx + PS_PPUpx + LB_PPUpx + AV_PPUpx + RB_PPUpx);
	protected
		procedure InitPulses; override;

		function  PPUpx2pos(PPUpx: Integer): Integer; inline;

		procedure SetupField;
	public
		dot_crawl_offset: 0..2;

		constructor Create; override;

		procedure Changed;  override;
		procedure Modulate; override;
	end;


implementation

{$R-}{$Q-}  // switch off overflow and range checking

// ************************************************************************************************
// TNTSCCRT_NES
// ************************************************************************************************

constructor TNTSCCRT_NES.Create;
begin
	inherited Create;

	CRT_CHROMA_PATTERN := 2;

	CRT_TOP          := 15;  // first line with active video
	CRT_BOT          := 255; // final line with active video
	CRT_CB_FREQ      := 4;   // carrier frequency relative to sample rate
	CRT_CC_VPER      := 3;   // vertical period in which the artifacts repeat
	CRT_HSYNC_WINDOW := 6;   // search windows, in samples
	CRT_VSYNC_WINDOW := 6;
	CRT_HSYNC_THRESH := 4;
	CRT_VSYNC_THRESH := 94;

	// IRE units (100 = 1.0V, -40 = 0.0V)
	// https://www.nesdev.org/wiki/NTSC_video#Terminated_measurement
	WHITE_LEVEL := 100;
	BURST_LEVEL := 30;
	BLACK_LEVEL := 0;
	BLANK_LEVEL := 0;
	SYNC_LEVEL  := -37;

	Changed;
end;

procedure TNTSCCRT_NES.Changed;
begin
	inherited;

	SetupField;
end;

// convert pixel offset to its corresponding point on the sampled line
function TNTSCCRT_NES.PPUpx2pos(PPUpx: Integer): Integer; inline;
begin
	Result := PPUpx * CRT_HRES div LINE_PPUpx;
end;

procedure TNTSCCRT_NES.InitPulses;
begin
	// starting points for all the different pulses
	FP_BEG   := PPUpx2pos(0);                                           // front porch point
	SYNC_BEG := PPUpx2pos(FP_PPUpx);                                    // sync tip point
	BW_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx);                       // breezeway point
	CB_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx + BW_PPUpx);            // color burst point
	BP_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx + BW_PPUpx + CB_PPUpx); // back porch point
	AV_BEG   := PPUpx2pos(HB_PPUpx + PS_PPUpx + LB_PPUpx);              // PPU active video point
	AV_LEN   := PPUpx2pos(AV_PPUpx);                                    // active video length
end;

procedure TNTSCCRT_NES.SetupField;
var
	n, t: Integer;
	line: PInt8;
begin
	for n := 0 to CRT_VRES-1 do
	begin
		line := @analog[n * CRT_HRES];
		t := LINE_BEG;

		if (n >= 259) and (n <= CRT_VRES) then
		begin
			// vertical sync scanlines
			while t < SYNC_BEG       do begin line[t] := BLANK_LEVEL; Inc(t); end; // FP
			while t < PPUpx2pos(327) do begin line[t] := SYNC_LEVEL;  Inc(t); end; // sync separator
			while t < CRT_HRES       do begin line[t] := BLANK_LEVEL; Inc(t); end; // blank
		end
		else
		begin
			// prerender/postrender/video scanlines
			while t < SYNC_BEG do begin line[t] := BLANK_LEVEL; Inc(t); end; // FP
			while t < BW_BEG   do begin line[t] := SYNC_LEVEL;  Inc(t); end; // SYNC
			while t < CRT_HRES do begin line[t] := BLANK_LEVEL; Inc(t); end;
		end;
	end;
end;

procedure TNTSCCRT_NES.Modulate;

	function CC_PHASE(phase: Integer): Integer; inline;
	begin
		if CRT_CHROMA_PATTERN = 1 then
		begin
			// 227.5 subcarrier cycles per line means every other line has reversed phase
			if (phase and 1) = 1 then
				Result := -1
			else
				Result := +1;
		end
		else
			Result := 1;
	end;

var
	n, x, y, xo, yo, sn, t, cb, sy,
	destw, desth, bpp, ire, xoff,
	rA, gA, bA, fy, fi, fq: Integer;
	ccmodI, ccmodQ, ccburst, iccf: array[0..{CRT_CC_VPER}3-1, 0..CRT_CC_SAMPLES-1] of Integer; // color phases
	line: PInt8;
	pix: PByte;
begin
    destw := AV_LEN;
    desth := CRT_LINES;
	bpp := crt_bpp4fmt[Format];

	dot_crawl_offset := (dot_crawl_offset + 1) mod 3;

	for y := 0 to CRT_CC_VPER-1 do
	begin
		xo := (y + dot_crawl_offset) * (360 div CRT_CC_VPER);
		for x := 0 to CRT_CC_SAMPLES-1 do
		begin
			n := xo + x * (360 div CRT_CC_SAMPLES);
			sn := crt_sin14((Hue + 90 + n + 33) * 8192 div 180);
			ccburst[y,x] := SarLongint(sn, 10);
			sn := crt_sin14(n * 8192 div 180);
			ccmodI [y,x] := SarLongint(sn, 10);
			sn := crt_sin14((n - 90) * 8192 div 180);
			ccmodQ [y,x] := SarLongint(sn, 10);
		end;
	end;

	xo := AV_BEG  + xoffset;
	yo := CRT_TOP + yoffset;

	// align signal
	xo := xo and (not 3);

	for y := 0 to desth-1 do
	begin
		sy := (y * Height) div desth;
		if sy > Height then sy := Height;
		if sy < 0 then sy := 0;

		n := y + yo;
		line := @analog[n * CRT_HRES];
		n := n mod CRT_CC_VPER;

		// CB_CYCLES of color burst at 3.579545 Mhz
		for t := CB_BEG to CB_BEG + (CB_CYCLES * CRT_CB_FREQ) - 1 do
		begin
			cb := ccburst[n, t mod CRT_CC_SAMPLES];
			line[t] := SarLongint(cb * BURST_LEVEL + BLANK_LEVEL, 5);
			iccf[n, t mod CRT_CC_SAMPLES] := line[t];
		end;
		sy *= Width;

		for x := 0 to destw-1 do
		begin
			pix := @data[(x * Width div destw + sy) * bpp];
			case Format of
				CRT_PIX_FORMAT_RGB,
				CRT_PIX_FORMAT_RGBA:
				begin
					rA := pix[0];
					gA := pix[1];
					bA := pix[2];
				end;
				CRT_PIX_FORMAT_BGR,
				CRT_PIX_FORMAT_BGRA:
				begin
					rA := pix[2];
					gA := pix[1];
					bA := pix[0];
				end;
				CRT_PIX_FORMAT_ARGB:
				begin
					rA := pix[1];
					gA := pix[2];
					bA := pix[3];
				end;
				CRT_PIX_FORMAT_ABGR:
				begin
					rA := pix[3];
					gA := pix[2];
					bA := pix[1];
				end;
				else
					rA := 0;
					gA := 0;
					bA := 0;
			end;

			// RGB to YIQ
			fy := SarLongint(19595 * rA + 38470 * gA +  7471 * bA, 14);
			fi := SarLongint(39059 * rA - 18022 * gA - 21103 * bA, 14);
			fq := SarLongint(13894 * rA - 34275 * gA + 20382 * bA, 14);
			ire := BLACK_LEVEL + Black_point;

			xoff := (x + xo) mod CRT_CC_SAMPLES;

            fi  := SarLongint(fi * ccmodI[n, xoff], 4);
            fq  := SarLongint(fq * ccmodQ[n, xoff], 4);
			ire += SarLongint((fy + fi + fq) * (WHITE_LEVEL * White_point div 100), 10);
			if ire < 0   then ire := 0
			else
			if ire > 110 then ire := 110;

			analog[(x + xo) + (y + yo) * CRT_HRES] := ire;
		end;
	end;

	for n := 0 to CRT_CC_VPER-1 do
		for x := 0 to CRT_CC_SAMPLES-1 do
			ccf[n,x] := iccf[n,x] << 7;
end;

end.

