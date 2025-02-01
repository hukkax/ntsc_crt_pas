{*****************************************************************************
 *
 * NTSC/CRT - Integer-only NTSC video signal encoding / decoding emulation
 *
 * An interface to convert NES PPU output in RGB form to an analog NTSC signal.
 *
 *   by EMMIR 2018-2023
 *   FreePascal port by hukka 2025
 *
 *   YouTube: https://www.youtube.com/@EMMIR_KC/videos
 *   Discord: https://discord.com/invite/hdYctSmyQJ
 *
 *****************************************************************************}
unit ntsc_crt_nes;

{$MODE Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
	Classes, SysUtils,
	ntsc_crt_base;

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
	// convert pixel offset to its corresponding point on the sampled line
		function  PPUpx2pos(PPUpx: Integer): Integer; inline;
		procedure SetupField;
	public
		dot_crawl_offset: 0..2;
		border_color:     Cardinal; // either BG or black

		constructor Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer); override;

		procedure Modulate; override;
	end;


implementation

// ************************************************************************************************
// Utility
// ************************************************************************************************

// ************************************************************************************************
// Filters
// ************************************************************************************************

// ************************************************************************************************
// TNTSCCRT_NES
// ************************************************************************************************

constructor TNTSCCRT_NES.Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer);
begin
	inherited Create(aWidth, aHeight, aFormat, Buffer);

	CRT_CHROMA_PATTERN := 2;

	CRT_TOP        := 15;  // first line with active video
	CRT_BOT        := 255; // final line with active video
	CRT_CC_VPER    := 3;   // vertical period in which the artifacts repeat
	CRT_HSYNC_WINDOW := 6; // search windows, in samples
	CRT_VSYNC_WINDOW := 6;

	// starting points for all the different pulses
	FP_BEG   := PPUpx2pos(0);                                           // front porch point
	SYNC_BEG := PPUpx2pos(FP_PPUpx);                                    // sync tip point
	BW_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx);                       // breezeway point
	CB_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx + BW_PPUpx);            // color burst point
	BP_BEG   := PPUpx2pos(FP_PPUpx + SYNC_PPUpx + BW_PPUpx + CB_PPUpx); // back porch point
	//LAV_BEG  := PPUpx2pos(HB_PPUpx);                                    // full active video point
	AV_BEG   := PPUpx2pos(HB_PPUpx + PS_PPUpx + LB_PPUpx);              // PPU active video point
	AV_LEN   := PPUpx2pos(AV_PPUpx);                                    // active video length

	DoInit;
	OptionsChanged;
end;

// convert pixel offset to its corresponding point on the sampled line
function TNTSCCRT_NES.PPUpx2pos(PPUpx: Integer): Integer; inline;
begin
	Result := PPUpx * CRT_HRES div LINE_PPUpx;
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

const
	evens: array [0..3] of Byte = ( 46, 50, 96, 100 );
	odds:  array [0..3] of Byte = (  4, 50, 96, 100 );
var
	n, x, y, xo, yo, sn, cs, t, cb, sy,
	destw, desth, bpp, ire, xoff,
	rA, gA, bA, fy, fi, fq: Integer;
	ccmodI, ccmodQ, ccburst, iccf: array[0..{CRT_CC_VPER}3-1, 0..CRT_CC_SAMPLES-1] of Integer; // color phases
	line: PInt8;
	pix: PByte;
begin
	{$R-}
    destw := AV_LEN;
    desth := CRT_LINES;

	if not initialized then
	begin
		SetupField;
		initialized := True;
	end;

	for y := 0 to CRT_CC_VPER - 1 do
	begin
		xo := (y + dot_crawl_offset) * (360 div CRT_CC_VPER);
		for x := 0 to CRT_CC_SAMPLES - 1 do
		begin
			n := xo + x * (360 div CRT_CC_SAMPLES);
			crt_sincos14(sn, cs, (Hue + 90 + n + 33) * 8192 div 180);
			ccburst[y,x] := SarLongint(sn, 10);
			crt_sincos14(sn, cs, n * 8192 div 180);
			ccmodI [y,x] := SarLongint(sn, 10);
			crt_sincos14(sn, cs, (n - 90) * 8192 div 180);
			ccmodQ [y,x] := SarLongint(sn, 10);
		end;
	end;

	bpp := crt_bpp4fmt(Format);
	if bpp = 0 then Exit; // just to be safe

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
			line[t] := SarLongint( ((BLANK_LEVEL + (cb * BURST_LEVEL))), 5);
			iccf[n, t mod CRT_CC_SAMPLES] := line[t];
		end;
		sy *= Width;

		for x := 0 to destw-1 do
		begin
			pix := @data[(((x * Width) div destw) + sy) * bpp];
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
			ire += SarLongint( (fy + fi + fq) * (WHITE_LEVEL * White_point div 100), 10);
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

