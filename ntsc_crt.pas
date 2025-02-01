{*****************************************************************************
 *
 * NTSC/CRT - Integer-only NTSC video signal encoding / decoding emulation
 *
 *   by EMMIR 2018-2023
 *   FreePascal port by hukka 2025
 *
 *   YouTube: https://www.youtube.com/@EMMIR_KC/videos
 *   Discord: https://discord.com/invite/hdYctSmyQJ
 *
 *****************************************************************************}
unit ntsc_crt;

{$MODE Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
	Classes, SysUtils,
	ntsc_crt_base;

type
	TNTSCCRT = class(TNTSCCRTBase)
	type
		TVHSMode = ( VHS_NONE, VHS_SP, VHS_LP, VHS_EP );
	protected
		FVHSMode: TVHSMode;

		procedure SetVHSMode(Value: TVHSMode);
	public
		property VHSMode: TVHSMode read FVHSMode write SetVHSMode;

		constructor Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer); override;

		procedure Modulate; override;
	end;


implementation



// ************************************************************************************************
// Utility
// ************************************************************************************************

const
	EXP_P    = 11;
	EXP_ONE  = 1 << EXP_P;
	EXP_MASK = EXP_ONE - 1;
	EXP_PI   = 6434;

	e11: array [0..4] of Cardinal = (
	    EXP_ONE,
	    5567,  // e
	    15133, // e^2
	    41135, // e^3
	    111817 // e^4
	);


function EXP_MUL(x, y: Integer): Integer; inline;
begin
	{$R-}
	Result := (x * y) >> EXP_P;
end;

function EXP_DIV(x, y: Integer): Integer; inline;
begin
	Result := (x << EXP_P) div y;
end;

// fixed point e^x
function expx(n: Integer): Integer;
var
	i, idx, nxt, acc, del: Integer;
	neg: Boolean;
begin
	Result := EXP_ONE;
	if n = 0 then
		Exit;

	neg := n < 0;
	if neg then
		n := -n;

	idx := n >> EXP_P;
	for i := 0 to (idx div 4)-1 do
		Result := EXP_MUL(Result, e11[4]);

	idx := idx and 3;
	if idx > 0 then
		Result := EXP_MUL(Result, e11[idx]);

	n := n and EXP_MASK;
	nxt := EXP_ONE;
	acc := 0;
	del := 1;
	for i := 1 to 16 do
	begin
		Inc(acc, nxt div del);
		nxt := EXP_MUL(nxt, n);
		del := del * i;
		if (del > nxt) or (nxt <= 0) or (del <= 0) then
			Break;
	end;

    Result := EXP_MUL(Result, acc);
    if neg then
        Result := EXP_DIV(EXP_ONE, Result);
end;

// ************************************************************************************************
// Filters
// ************************************************************************************************

type
	// infinite impulse response low pass filter for bandlimiting YIQ
	TIIRLP = record
		c, h: Integer;

		procedure init_iir(freq, limit: Integer);
		procedure reset_iir;
		function  iirf(s: Integer): Integer;
	end;

var
	iirY, iirI, iirQ: TIIRLP;

// freq  - total bandwidth
// limit - max frequency
//
procedure TIIRLP.init_iir(freq, limit: Integer);
var
	rate: Integer; // cycles/pixel rate
begin
    rate := (freq << 9) div limit;
	h := 0;
	c := EXP_ONE - expx(-((EXP_PI << 9) div rate));
end;

procedure TIIRLP.reset_iir;
begin
	h := 0;
end;

function TIIRLP.iirf(s: Integer): Integer;
begin
	{$R-}
	h += EXP_MUL(s - h, c);
	Result := h;
end;

// ************************************************************************************************
// TNTSCCRT
// ************************************************************************************************

procedure TNTSCCRT.SetVHSMode(Value: TVHSMode);
begin
	FVHSMode := Value;

	// frequencies for bandlimiting
	case Value of
		VHS_NONE:
		begin
			Y_FREQ := 420000;  // Luma   (Y) 4.2  MHz of the 14.31818 MHz
			I_FREQ := 150000;  // Chroma (I) 1.5  MHz of the 14.31818 MHz
			Q_FREQ := 55000;   // Chroma (Q) 0.55 MHz of the 14.31818 MHz
		end;
		VHS_SP:
		begin
			Y_FREQ := 300000;  // Luma   (Y) 3.0  MHz of the 14.31818 MHz
			I_FREQ := 62700;   // Chroma (I) 627  kHz of the 14.31818 MHz
			Q_FREQ := I_FREQ;
		end;
		VHS_LP:
		begin;
			Y_FREQ := 240000;  // Luma   (Y) 2.4  MHz of the 14.31818 MHz
			I_FREQ := 40000;   // Chroma (I) 400  kHz of the 14.31818 MHz
			Q_FREQ := I_FREQ;
		end;
		VHS_EP:
		begin
			Y_FREQ := 200000;  // Luma   (Y) 2.0  MHz of the 14.31818 MHz
			I_FREQ := 37000;   // Chroma (I) 370  kHz of the 14.31818 MHz
			Q_FREQ := I_FREQ;
		end;
	end;

	L_FREQ := 1431818; // full line

	if initialized then
		OptionsChanged;
end;

constructor TNTSCCRT.Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer);
begin
	inherited Create(aWidth, aHeight, aFormat, Buffer);

	CRT_CHROMA_PATTERN := 1;
	CRT_TOP := 21;  // first line with active video
	CRT_BOT := 261; // final line with active video
	CRT_HSYNC_WINDOW := 8;
	CRT_VSYNC_WINDOW := 8;

	VHSMode := VHS_SP;
	DoAberration := True;
	DoVHSNoise := True;
	DoBloom := True;

	DoInit;
	OptionsChanged;
end;

procedure TNTSCCRT.Modulate;

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
	x, y, xo, yo, sn, cs,
	n, ph, bpp, t, cb, sy,
	fy, fi, fq,
	rA, gA, bA,
	ire, xoff,
	destw, desth,
	field_offset: Integer;
	inv_phase: Integer = 0;
	iccf, ccmodI, ccmodQ, ccburst: array[0..CRT_CC_SAMPLES-1] of Integer; // color phases
	line: PInt8;
	aberration: Integer = 0;
	offs: PByte;
	pix: PByte;
	//pix: Cardinal;
begin
	{$R-}
	destw := AV_LEN;
	desth := (CRT_LINES * 64500) >> 16;

	if not initialized then
	begin
		iirY.init_iir(L_FREQ, Y_FREQ);
		iirI.init_iir(L_FREQ, I_FREQ);
		iirQ.init_iir(L_FREQ, Q_FREQ);
		initialized := True;
	end;

	if not Stretch then
	begin
		destw := Width;
		desth := Height;
		if DoBloom then
		begin
			if destw > ((AV_LEN * 55500) >> 16) then
				destw := (AV_LEN * 55500) >> 16;
			if desth > ((CRT_LINES * 63500) >> 16) then
				desth := (CRT_LINES * 63500) >> 16;
		end
		else
		begin
			if destw > AV_LEN then
				destw := AV_LEN;
			if desth > ((CRT_LINES * 64500) >> 16) then
				desth := (CRT_LINES * 64500) >> 16;
		end;
	end
	else
	if DoBloom then
	begin
		destw := (AV_LEN * 55500) >> 16;
		desth := (CRT_LINES * 63500) >> 16;
	end;

	if not Monochrome then
	begin
		for x := 0 to CRT_CC_SAMPLES-1 do
		begin
			n := Hue + x * (360 div CRT_CC_SAMPLES);
			crt_sincos14(sn, cs, (n + 33) * 8192 div 180);
			ccburst[x] := SarLongint(sn, 10) and $FF;
			crt_sincos14(sn, cs, n * 8192 div 180);
			ccmodI[x] := SarLongint(sn, 10);
			crt_sincos14(sn, cs, (n - 90) * 8192 div 180);
			ccmodQ[x] := SarLongint(sn, 10);
		end;
	end
	else
	begin
		FillByte(ccburst[0], Length(ccburst)*SizeOf(Integer), 0);
		FillByte(ccmodI[0],  Length(ccmodI) *SizeOf(Integer), 0);
		FillByte(ccmodQ[0],  Length(ccmodQ) *SizeOf(Integer), 0);
	end;

	bpp := crt_bpp4fmt(Format);
	if bpp = 0 then Exit; // just to be safe

	xo := AV_BEG  + xoffset + (AV_LEN    - destw) div 2;
	yo := CRT_TOP + yoffset + (CRT_LINES - desth) div 2;

	field := field and 1;
	frame := frame and 1;
	if field = frame then
		inv_phase := 1
	else
		inv_phase := 0;
	ph := CC_PHASE(inv_phase);

	// align signal
	xo := xo and (not 3);
    if DoAberration then
		aberration := (Random(12) - 8) + 14;

	for n := 0 to CRT_VRES-1 do
	begin
		t := LINE_BEG;
		line := @analog[n * CRT_HRES];

		if (n <= 3) or ((n >= 7) and (n <= 9)) then
		begin
			// equalizing pulses - small blips of sync, mostly blank
			while t < (4   * CRT_HRES div 100) do begin line[t] := SYNC_LEVEL;  Inc(t); end;
			while t < (50  * CRT_HRES div 100) do begin line[t] := BLANK_LEVEL; Inc(t); end;
			while t < (54  * CRT_HRES div 100) do begin line[t] := SYNC_LEVEL;  Inc(t); end;
			while t < (100 * CRT_HRES div 100) do begin line[t] := BLANK_LEVEL; Inc(t); end;
		end
		else
		if (n >= 4) and (n <= 6) then
		begin
			if field = 1 then
			    offs := @odds[0]
			else
				offs := @evens[0];
			// vertical sync pulse - small blips of blank, mostly sync
			while t < (offs[0] * CRT_HRES div 100) do begin line[t] := SYNC_LEVEL;  Inc(t); end;
			while t < (offs[1] * CRT_HRES div 100) do begin line[t] := BLANK_LEVEL; Inc(t); end;
			while t < (offs[2] * CRT_HRES div 100) do begin line[t] := SYNC_LEVEL;  Inc(t); end;
			while t < (offs[3] * CRT_HRES div 100) do begin line[t] := BLANK_LEVEL; Inc(t); end;
		end
		else
		begin
			// video line
			if (not DoAberration) or (n < (CRT_VRES - aberration)) then
			begin
				while t < SYNC_BEG do begin line[t] := BLANK_LEVEL; Inc(t); end; // FP
				while t < BW_BEG   do begin line[t] := SYNC_LEVEL;  Inc(t); end; // SYNC
			end;

			while t < AV_BEG   do begin line[t] := BLANK_LEVEL; Inc(t); end; // BW + CB + BP
			if n < CRT_TOP then
				while t < CRT_HRES do begin line[t] := BLANK_LEVEL; Inc(t); end;

			// CB_CYCLES of color burst at 3.579545 Mhz
			for t := CB_BEG to (CB_BEG + (CB_CYCLES * CRT_CB_FREQ) - 1) do
			begin
				if CRT_CHROMA_PATTERN = 1 then
					cb := ccburst[(t + inv_phase * (CRT_CC_SAMPLES div 2)) mod CRT_CC_SAMPLES]
				else
					cb := ccburst[t mod CRT_CC_SAMPLES];
				line[t] := SarLongint( ((BLANK_LEVEL + (cb * BURST_LEVEL))), 5);
				iccf[t mod CRT_CC_SAMPLES] := line[t];
			end;
		end;
	end;

	// reset hsync every frame so only the bottom part is warped
	if VHSMode <> VHS_NONE then
		HSync := 0;

	for y := 0 to desth-1 do
	begin
		field_offset := (field * Height + desth) div desth div 2;

		sy := ((y * Height) div desth) + field_offset;
		if sy > Height then sy := Height;
		sy := sy * Width;

		iirY.reset_iir;
		iirI.reset_iir;
		iirQ.reset_iir;

		for x := 0 to destw-1 do
		begin
			//pix := (((x * Width) div destw) + sy) * bpp;
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
			// bandlimit Y,I,Q
			fy := iirY.iirf(fy);
			fi := SarLongint(iirI.iirf(fi) * ph * ccmodI[xoff], 4);
			fq := SarLongint(iirQ.iirf(fq) * ph * ccmodQ[xoff], 4);
			ire += SarLongint( (fy + fi + fq) * (WHITE_LEVEL * White_point div 100), 10);
			if ire < 0   then ire := 0
			else
			if ire > 110 then ire := 110;

			analog[(x + xo) + (y + yo) * CRT_HRES] := ire;
		end;
	end;

	if VHSMode <> VHS_NONE then
	begin
		for n := 0 to CRT_CC_VPER-1 do
			for x := 0 to CRT_CC_SAMPLES-1 do
				ccf[n,x] := 0;
	end
	else
	begin
		for n := 0 to CRT_CC_VPER-1 do
			for x := 0 to CRT_CC_SAMPLES-1 do
				ccf[n,x] := iccf[x] << 7;
	end;
end;

end.

