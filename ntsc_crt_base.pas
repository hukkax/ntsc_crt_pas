{*****************************************************************************
 *
 * NTSC/CRT - Integer-only NTSC video signal encoding / decoding emulation
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
unit ntsc_crt_base;

{$I ntsc_crt_options.inc}

interface

uses
	{$IFDEF MEASURE_TIMING} TimeMeasurer, {$ENDIF}
	Classes, SysUtils,
	ntsc_crt_common;

type
	TNTSCCRTBase = class
	type
		TOutRec = record
			y, i, q: Integer;
		end;

	const
		(*
		 *                      FULL HORIZONTAL LINE SIGNAL (~63500 ns)
		 * |---------------------------------------------------------------------------|
		 *   HBLANK (~10900 ns)                 ACTIVE VIDEO (~52600 ns)
		 * |-------------------||------------------------------------------------------|
		 *
		 *
		 *   WITHIN HBLANK PERIOD:
		 *
		 *   FP (~1500 ns)  SYNC (~4700 ns)  BW (~600 ns)  CB (~2500 ns)  BP (~1600 ns)
		 * |--------------||---------------||------------||-------------||-------------|
		 *      BLANK            SYNC           BLANK          BLANK          BLANK
		 *
		 *)
		LINE_BEG = 0;
		FP_ns    = 1500;      // front porch
		SYNC_ns  = 4700;      // sync tip
		BW_ns    = 600;       // breezeway
		CB_ns    = 2500;      // color burst
		BP_ns    = 1600;      // back porch
		AV_ns    = 52600;     // active video
		HB_ns    = (FP_ns + SYNC_ns + BW_ns + CB_ns + BP_ns); // h blank
		// line duration should be ~63500 ns
		LINE_ns  = (FP_ns + SYNC_ns + BW_ns + CB_ns + BP_ns + AV_ns);

	protected
		data:     PByte;   // input image data
		Format:   TCRTPixelFormat; // output pixel format
		output:   PByte;           // output image buffer
		outrec:   array of TOutRec;

		// faster color carrier convergence
		ccf: array of array of Integer;

		// seed for the 'random' noise
		randseed: Integer;

		// CRT input, can be noisy
		analog, inp: array of Int8;

		// factor to stretch img vertically onto the output img TODO
		v_fac: Cardinal;

		// interlaced modes only
		field, frame:  Integer;  // 0 = even, 1 = odd

		L_FREQ, Y_FREQ, I_FREQ, Q_FREQ: Cardinal;

		// 0 = vertical  chroma (228 chroma clocks per line)
		// 1 = checkered chroma (227.5 chroma clocks per line)
		// 2 = sawtooth  chroma (227.3 chroma clocks per line)
		CRT_CHROMA_PATTERN: Byte;

		CRT_CC_LINE: Word;

		CRT_CB_FREQ:    Byte; // in general, increasing CRT_CB_FREQ reduces blur and bleed
		CRT_HRES:       Word; // horizontal resolution
		CRT_VRES:       Word; // vertical resolution
		CRT_INPUT_SIZE: Cardinal;

		CRT_TOP:        Word; // first line with active video
		CRT_BOT:        Word; // final line with active video
		CRT_LINES:      Word; // number of active video lines

		CRT_CC_VPER:    Byte; // vertical period in which the artifacts repeat

		CRT_HSYNC_WINDOW,     // search windows, in samples
		CRT_VSYNC_WINDOW: Byte;

		// accumulated signal threshold required for sync detection.
		// Larger = more stable, until it's so large that it is never reached in which
		//          case the CRT won't be able to sync
		CRT_HSYNC_THRESH,
		CRT_VSYNC_THRESH: Byte;

		// starting points for all the different pulses
		FP_BEG, SYNC_BEG, BW_BEG, CB_BEG, BP_BEG, AV_BEG,
		AV_LEN: Integer;
		CB_CYCLES: Byte; // somewhere between 7 and 12 cycles

		// IRE units (100 = 1.0V, -40 = 0.0V)
		WHITE_LEVEL, BURST_LEVEL,
		BLACK_LEVEL, BLANK_LEVEL,
		SYNC_LEVEL:  Integer;

		eqY, eqI, eqQ: TEQF;

		procedure InitPulses; virtual;

		procedure SetChromaPattern(Value: Byte);

	public
		{$IFDEF MEASURE_TIMING}
		Timing: record
			Modulation,
			Demodulation: Single;
			Measurer:     TTimeMeasurer;
		end;
		{$ENDIF}

		Width,
		Height:      Word;    // output width/height

		xoffset:     Word;    // x offset in sample space. 0 is minimum value
		yoffset:     Word;    // y offset in # of lines. 0 is minimum value

		// image settings
		Stretch:     Boolean; // scale image to fit monitor?
		Monochrome:  Boolean; // monochrome or full color?
		Noise:       Byte;    // image noisiness
		// common monitor settings
		Hue, Brightness, Contrast, Saturation: Integer;
		// user-adjustable
		Black_point, White_point: Integer;
		// leave gaps between lines if necessary
		Scanlines: Byte;

		Progressive:  Boolean; // progressive or interlaced mode?

		DoFadePhosphors: Boolean;
		DoVSync:         Boolean;
		DoHSync:         Boolean;
		DoBloom:         Boolean;
		DoBlend:         Boolean;  // blend new field onto previous image?

		// VHS
		DoAberration:    Boolean;
		DoVHSNoise:      Boolean;  // want noise at the bottom of the frame?
		MaxRandom:       Cardinal;

		// keep track of sync over frames
		HSync, VSync: Integer;

		property  FirstLine:     Word read CRT_TOP;
		property  ChromaPattern: Byte read CRT_CHROMA_PATTERN write SetChromaPattern;

		constructor Create; virtual;
		destructor  Destroy; override;

		procedure Changed; virtual;
		procedure Reset; virtual;
		procedure Resize(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; DestBuffer: Pointer); virtual;

		procedure Modulate; virtual; abstract;
		procedure Demodulate; virtual;
		procedure FadePhosphors; virtual;
		procedure ProcessFrame(Buffer: Pointer = nil); virtual;
	end;


implementation

{$R-}{$Q-}  // switch off overflow and range checking

// ************************************************************************************************
// TNTSCCRTBase
// ************************************************************************************************

procedure TNTSCCRTBase.FadePhosphors;
var
	i: Integer;
	c: Cardinal;
	v: ^Cardinal;
begin
	v := @output[0];
	for i := 0 to Width*Height-1 do
	begin
		c := v[i] and $FFFFFF;
		v[i] :=
			(c >> 1 and $7F7F7F) +
			(c >> 2 and $3F3F3F) +
			(c >> 3 and $1F1F1F) +
			(c >> 4 and $0F0F0F);
	end;
end;

procedure TNTSCCRTBase.ProcessFrame(Buffer: Pointer);
begin
	if Buffer <> nil then
		Data := Buffer;

	if Data = nil then Exit;

	if field = 0 then
		frame := frame xor 1; // a frame is two fields

	if DoFadePhosphors then
		FadePhosphors
	else
		FillByte(output[0], Width*Height*crt_bpp4fmt[Format]-1, 0);

	{$IFDEF MEASURE_TIMING}
	Timing.Measurer.Start;
		Modulate;
	Timing.Measurer.Stop;
	Timing.Modulation := Timing.Measurer.MillisecondsFloat;

	Timing.Measurer.Start;
		Demodulate;
	Timing.Measurer.Stop;
	Timing.Demodulation := Timing.Measurer.MillisecondsFloat;
	{$ELSE}
	Modulate;
	Demodulate;
	{$ENDIF}

	if not Progressive then
		field := field xor 1;
end;

// Updates the output image parameters
// * aWidth:     width of the output image
// * aHeight:    height of the output image
// * aFormat:    pixel format of the output image
// * DestBuffer: pointer to output image data
//
procedure TNTSCCRTBase.Resize(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; DestBuffer: Pointer);
begin
	Width  := aWidth;
	Height := aHeight;
	Format := aFormat;
	output := DestBuffer;
end;

// Resets the CRT settings back to their defaults
//
procedure TNTSCCRTBase.Reset;
begin
	Hue         := 0;
	Saturation  := 75;
	Brightness  := 0;
	Contrast    := 180;
	Black_point := 0;
	White_point := 100;
	HSync := 0;
	VSync := 0;

	Stretch := True;
	Scanlines := 0;
	Noise := 6;
	Monochrome := False;
	Progressive := False;
	DoBlend := False;
	DoVSync := True;
	DoHSync := True;
	DoBloom := False;
	DoAberration := True;
	DoVHSNoise := False;
	DoFadePhosphors := True;
end;

procedure TNTSCCRTBase.SetChromaPattern(Value: Byte);
begin
	if CRT_CHROMA_PATTERN <> Value then
	begin
		if Value > 2 then Value := 0;
		CRT_CHROMA_PATTERN := Value;
		Changed;
	end;
end;

constructor TNTSCCRTBase.Create;
begin
	inherited Create;

	CRT_CHROMA_PATTERN := 1;

	CRT_TOP  := 21;  // first line with active video
	CRT_BOT  := 261; // final line with active video
	CRT_VRES := 262; // vertical resolution
	CB_CYCLES := 10;
	CRT_CB_FREQ := 4;   // carrier frequency relative to sample rate
	CRT_CC_VPER := 1;
	CRT_HSYNC_WINDOW := 8;
	CRT_VSYNC_WINDOW := 8;
	CRT_HSYNC_THRESH := 4;
	CRT_VSYNC_THRESH := 94;

	WHITE_LEVEL := 100;
	BURST_LEVEL := 20;
	BLACK_LEVEL := 7;
	BLANK_LEVEL := 0;
	SYNC_LEVEL  := -40;

	MaxRandom := High(MaxInt);

	Reset;
	Changed;

	{$IFDEF MEASURE_TIMING}
	Timing.Measurer.Init;
	{$ENDIF}
end;

procedure TNTSCCRTBase.InitPulses;

	// convert nanosecond offset to its corresponding point on the sampled line
	function ns2pos(ns: Integer): Integer; inline;
	begin
		Result := ns * CRT_HRES div LINE_ns;
	end;

begin
	// starting points for all the different pulses
	FP_BEG   := ns2pos(0);
	SYNC_BEG := ns2pos(FP_ns);
	BW_BEG   := ns2pos(FP_ns + SYNC_ns);
	CB_BEG   := ns2pos(FP_ns + SYNC_ns + BW_ns);
	BP_BEG   := ns2pos(FP_ns + SYNC_ns + BW_ns + CB_ns);
	AV_BEG   := ns2pos(HB_ns);
	AV_LEN   := ns2pos(AV_ns);
end;

procedure TNTSCCRTBase.Changed;

	// kilohertz to line sample conversion
	function kHz2L(kHz: Integer): Integer;
	begin
		if L_FREQ > 0 then
			Result := Round((CRT_HRES * (kHz * 100) / L_FREQ))
		else
			Result := 0;
	end;

var
	i: Integer;
begin
	randseed := 194;

	HSync := 0;
	VSync := 0;

	// chroma clocks (subcarrier cycles) per line
	case CRT_CHROMA_PATTERN of
		1: CRT_CC_LINE := 2275;
		2: CRT_CC_LINE := 2273;
		else // this will give the 'rainbow' effect in the famous waterfall scene
		   CRT_CC_LINE := 2280;
	end;

	CRT_HRES       := CRT_CC_LINE * CRT_CB_FREQ div 10; // horizontal resolution
	CRT_INPUT_SIZE := CRT_HRES * CRT_VRES;
	CRT_LINES      := CRT_BOT - CRT_TOP; // number of active video lines

	InitPulses;

	SetLength(ccf,    CRT_CC_VPER, CRT_CC_SAMPLES);
	SetLength(analog, CRT_INPUT_SIZE);
	SetLength(inp,    CRT_INPUT_SIZE);
	SetLength(outrec, AV_LEN);

	for i := 0 to CRT_CC_VPER-1 do
		FillChar(ccf[i,0], CRT_CC_SAMPLES*SizeOf(Integer), 0);
	FillChar(analog[0], SizeOf(analog[0]) * Length(analog), 0);
	FillChar(inp[0],    SizeOf(inp[0])    * Length(inp), 0);
	for i := 0 to Length(outrec)-1 do
		outrec[i] := Default(TOutRec);

	// band gains are pre-scaled as 16-bit fixed point
	// if you change the EQ_P define, you'll need to update these gains too
	//
	{$IFDEF CRT_CC_5_SAMPLES}
	eqY.Init(kHz2L(1500), kHz2L(3000), CRT_HRES, 65536, 12192, 7775);
	eqI.Init(kHz2L(80),   kHz2L(1150), CRT_HRES, 65536, 65536, 1311);
	eqQ.Init(kHz2L(80),   kHz2L(1000), CRT_HRES, 65536, 65536, 0);
	{$ELSE}
	eqY.Init(kHz2L(1500), kHz2L(3000), CRT_HRES, 65536, 8192, 9175);
	eqI.Init(kHz2L(80),   kHz2L(1150), CRT_HRES, 65536, 65536, 1311);
	eqQ.Init(kHz2L(80),   kHz2L(1000), CRT_HRES, 65536, 65536, 0);
	{$ENDIF}
end;

destructor TNTSCCRTBase.Destroy;
begin
	inherited Destroy;
end;

// Demodulates the NTSC signal generated by Modulate()
//
procedure TNTSCCRTBase.Demodulate;
label
	found_vsync,
	found_field;
const
	xnudge = -3;
	ynudge = +3;
var
	yiqA, yiqB: ^TOutRec;
	sig: PInt8;
	i, j, line, rn: Integer;
	s: Integer = 0;
	fld, ratio: Integer;
	ccr: PInteger; // color carrier signal
	huesn, huecs: Integer;
	bright: Integer;
	bpp, pitch: Integer;
	prev_e: Integer; // filtered beam energy per scan line
	max_e: Integer;  // approx maximum energy in a scan line
	cs, nn,
	aa, bb, LT, RT, p, n,
	y, q, r, g, b,
	scanL, dx,
	dci, dcq, // decoded I, Q
	xpos, ypos,
	line_beg, line_end, phasealign, line_w: Integer;
	pos, ln, scanR: Cardinal;
	cL, cR: PByte;
	{$IFDEF CRT_CC_5_SAMPLES}
	dciA, dciB, dcqA, dcqB,
	sn, ang, off180, off90,
	peakA, peakB: Integer;
	waveI, waveQ: array [0..CRT_CC_SAMPLES-1] of Integer;
	{$ELSE}
	wave: array [0..CRT_CC_SAMPLES-1] of Integer;
	{$ENDIF}
begin
	bpp := crt_bpp4fmt[Format];
	pitch := Width * bpp;

	crt_sincos14(huesn, huecs, (Hue mod 360 + 33) * 8192 div 180);
	huesn := {%H-}SarLongint(huesn, 11); // make 4-bit
	huecs := {%H-}SarLongint(huecs, 11);

	rn := randseed;

	if not DoVSync then
	begin
		// determine field before we add noise,
		// otherwise it's not reliably recoverable
		fld := CRT_HRES;

		for i := -CRT_VSYNC_WINDOW to CRT_VSYNC_WINDOW-1 do
		begin
			line := POSMOD(VSync + i, CRT_VRES);
			sig  := @analog[line * CRT_HRES];
			s := 0;
			for j := 0 to CRT_HRES-1 do
			begin
				s += sig[j];
				if s <= (CRT_VSYNC_THRESH * SYNC_LEVEL) then
				begin
					fld := j;
					goto found_field;
				end;
			end;
		end;

found_field:
		// if vsync signal was in second half of line, odd field
		fld := BoolToVal[fld > (CRT_HRES div 2)];
		VSync := -3;
	end;

	if DoVHSNoise then
		line := (Random(8) - 4) + 14;

    for i := 0 to CRT_INPUT_SIZE-1 do
	begin
        nn := Noise;

		if DoVHSNoise then
		begin
			if (i > (CRT_INPUT_SIZE - CRT_HRES * 26)) and
			   (i > (CRT_INPUT_SIZE - CRT_HRES * (16 + (Random(20) - 10)))) and
			   (i < (CRT_INPUT_SIZE - CRT_HRES * ( 5 + (Random(8)  -  4)))) then
			begin
				cs := crt_cos14((i * {%H-}line) div CRT_HRES * 8192 div 180);
				nn := SarLongint(cs, 8);
			end;
			rn := Random(MaxRandom);
		end
		else
		begin
			if nn > 128 then
			begin
				Dec(nn, 128);
				nn := nn * nn div 4 + 129;
			end;
			rn := 214019 * rn + 140327895;
		end;

        // signal + noise
        s := analog[i] + SarLongint(((SarLongint(rn, 16) and $FF - $7F) * nn), 8);
        if s > +127 then s := +127
		else
        if s < -127 then s := -127;
        inp[i] := s;
    end;

    randseed := rn;

	if DoVSync then
	begin
		// Look for vertical sync.
		//
		// This is done by integrating the signal and
		// seeing if it exceeds a threshold. The threshold of
		// the vertical sync pulse is much higher because the
		// vsync pulse is a lot longer than the hsync pulse.
		// The signal needs to be integrated to lessen
		// the noise in the signal.
		fld := CRT_HRES;

		for i := -CRT_VSYNC_WINDOW to CRT_VSYNC_WINDOW-1 do
		begin
			line := POSMOD(VSync + i, CRT_VRES);
			sig  := @inp[line * CRT_HRES];
			s := 0;
			for j := 0 to CRT_HRES-1 do
			begin
				s += sig[j];
				// increase the multiplier to make the vsync
				// more stable when there is a lot of noise
				if s <= (CRT_VSYNC_THRESH * SYNC_LEVEL) then
				begin
					fld := j;
					goto found_vsync;
				end;
			end;
		end;

found_vsync:
		VSync := line; // vsync found (or gave up) at this line
		// if vsync signal was in second half of line, odd field
		fld := BoolToVal[fld > (CRT_HRES div 2)];
	end;

	if DoBloom then
	begin
		max_e  := (128 + (Noise div 2)) * AV_LEN;
		prev_e := 16384 div 8;
	end;

    // ratio of output height to active video lines in the signal
    ratio := (Height << 16) div CRT_LINES;
    ratio := SarLongint(ratio + 32768, 16);
    fld := {%H-}fld * (ratio div 2);

    for line := CRT_TOP to CRT_BOT-1 do
	begin
        line_beg := (line - CRT_TOP + 0) * (Height + v_fac) div CRT_LINES + fld;
        line_end := (line - CRT_TOP + 1) * (Height + v_fac) div CRT_LINES + fld;

        if line_beg >= Height then Continue;
        if line_end >  Height then line_end := Height;

        // Look for horizontal sync.
        // See comment above regarding vertical sync.
        ln  := POSMOD(line + VSync, CRT_VRES) * CRT_HRES;
        sig := @inp[ln + HSync];
        s := 0;
		j := CRT_HSYNC_WINDOW;
        for i := -CRT_HSYNC_WINDOW to CRT_HSYNC_WINDOW-1 do
		begin
            s += sig[SYNC_BEG + i];
            if s <= (CRT_HSYNC_THRESH * SYNC_LEVEL) then
			begin
				j := i;
				Break;
			end;
        end;

		if DoHSync then
			HSync := POSMOD(j + HSync, CRT_HRES)
		else
			HSync := 0;

        xpos := POSMOD(AV_BEG + HSync + xnudge, CRT_HRES);
        ypos := POSMOD(line + VSync + ynudge, CRT_VRES);
        pos  := ypos * CRT_HRES + xpos;
        ccr  := @ccf[ypos mod CRT_CC_VPER, 0];

		{$IFDEF CRT_CC_5_SAMPLES}
		sig := @inp[ln + (HSync - (HSync mod CRT_CC_SAMPLES))];
		{$ELSE}
		sig := @inp[ln + (HSync and (not 3))]; // faster
		{$ENDIF}

        for i := CB_BEG to CB_BEG + (CB_CYCLES * CRT_CB_FREQ) - 1 do
		begin
			p := ccr[i mod CRT_CC_SAMPLES] * 127 div 128; // fraction of the previous
            n := sig[i];                 // mixed with the new sample
            ccr[i mod CRT_CC_SAMPLES] := p + n;
        end;

        phasealign := POSMOD(HSync, CRT_CC_SAMPLES);

		{$IFDEF CRT_CC_5_SAMPLES}
		ang := Hue mod 360;
		off180 := CRT_CC_SAMPLES div 2;
		off90  := CRT_CC_SAMPLES div 4;
		peakA := phasealign + off90;
		peakB := phasealign + 0;
		dciA := 0; dciB := 0; dcqA := 0; dcqB := 0;
		// amplitude of carrier = saturation, phase difference = hue
		dciA := ccr[peakA mod CRT_CC_SAMPLES];
		// average
		dciB := (ccr[(peakA + off180) mod CRT_CC_SAMPLES]
			  + ccr[(peakA + off180 + 1) mod CRT_CC_SAMPLES]) / 2;
		dcqA := ccr[(peakB + off180) mod CRT_CC_SAMPLES];
		dcqB := ccr[(peakB) mod CRT_CC_SAMPLES];
		dci := dciA - dciB;
		dcq := dcqA - dcqB;
		// create wave tables and rotate them by the hue adjustment angle
		for i := 0 to 4 do
		begin
			crt_sincos14(sn, cs, ang * 8192 div 180);
			waveI[i] := ((dci * cs + dcq * sn) >> 15) * saturation;
			// Q is offset by 90
			crt_sincos14(sn, cs, (ang + 90) * 8192 div 180);
			waveQ[i] := ((dci * cs + dcq * sn) >> 15) * saturation;
			ang += (360 div CRT_CC_SAMPLES);
		end;
		{$ELSE}
		// amplitude of carrier = saturation, phase difference = hue
		dci := ccr[(phasealign + 1) and 3] - ccr[(phasealign + 3) and 3];
		dcq := ccr[(phasealign + 2) and 3] - ccr[(phasealign + 0) and 3];

		wave[0] := Trunc(SarLongint((dci * huecs - dcq * huesn), 4) * (Saturation / 8));
		wave[1] := Trunc(SarLongint((dcq * huecs + dci * huesn), 4) * (Saturation / 8));
		wave[2] := -wave[0];
		wave[3] := -wave[1];
		{$ENDIF}

        sig := @inp[pos];

		if DoBloom then
		begin
			s := 0;
			for i := 0 to AV_LEN-1 do
				s += sig[i]; // sum up the scan line

			// bloom emulation
			prev_e := ({%H-}prev_e * 123 div 128) + (((SarLongint(max_e{%H-}, 1) - s) << 10) div {%H-}max_e);
			line_w := (AV_LEN * 112 div 128) + SarLongint(prev_e, 9);

			dx := (line_w << 12) div Width;
			scanL := ((AV_LEN div 2) - (SarLongint(line_w, 1)) + 8) << 12;
			scanR := (AV_LEN - 1) << 12;

			LT := SarLongint(scanL, 12);
			RT := SarLongint(scanR, 12);
		end
		else
		begin
			dx := ((AV_LEN - 1) << 12) div Width;
			scanL := 0;
			scanR := (AV_LEN - 1) << 12;
			LT := 0;
			RT := AV_LEN;
		end;

        eqY.Reset;
        eqI.Reset;
        eqQ.Reset;

		bright := Brightness - (BLACK_LEVEL + black_point);

		for i := LT to RT-1 do
		begin
            outrec[i].y := eqY.EQF(sig[i] + bright) << 4;
			{$IFDEF CRT_CC_5_SAMPLES}
			outrec[i].i := eqI.EQF(sig[i] * waveI[i mod CRT_CC_SAMPLES] >> 9) >> 3;
			outrec[i].q := eqQ.EQF(sig[i] * waveQ[i mod CRT_CC_SAMPLES] >> 9) >> 3;
			{$ELSE}
			outrec[i].i := SarLongint(eqI.EQF(SarLongint(sig[i] * wave[(i + 0) and 3], 9)), 3);
			outrec[i].q := SarLongint(eqQ.EQF(SarLongint(sig[i] * wave[(i + 3) and 3], 9)), 3);
			{$ENDIF}
		end;

        cL := @output[line_beg * pitch];
        cR := @cL[pitch];
		pos := scanL;

		while (pos < scanR) and (cL < cR) do
		begin
            RT := pos and $FFF;
            LT := $FFF - RT;

            s := pos >> 12;
            yiqA := @outrec[s];
            yiqB := @outrec[s+1];

            // interpolate between samples if needed
            y := SarLongint(yiqA.y * LT,  2) + SarLongint(yiqB.y * RT,  2);
            i := SarLongint(yiqA.i * LT, 14) + SarLongint(yiqB.i * RT, 14);
            q := SarLongint(yiqA.q * LT, 14) + SarLongint(yiqB.q * RT, 14);

            // YIQ to RGB
            r := ClampToByte(SarLongint(y + 3879 * i + 2556 * q, 12) * Contrast >> 8);
            g := ClampToByte(SarLongint(y - 1126 * i - 2605 * q, 12) * Contrast >> 8);
            b := ClampToByte(SarLongint(y - 4530 * i + 7021 * q, 12) * Contrast >> 8);

            if DoBlend then
			begin
                aa := (r << 16) or (g << 8) or b;

                case Format of
                    CRT_PIX_FORMAT_RGB,
                    CRT_PIX_FORMAT_RGBA:
                        bb := (cL[0] << 16) or (cL[1] << 8) or cL[2];
                    CRT_PIX_FORMAT_BGR,
                    CRT_PIX_FORMAT_BGRA:
                        bb := (cL[2] << 16) or (cL[1] << 8) or cL[0];
                    CRT_PIX_FORMAT_ARGB:
                        bb := (cL[1] << 16) or (cL[2] << 8) or cL[3];
                    CRT_PIX_FORMAT_ABGR:
                        bb := (cL[3] << 16) or (cL[2] << 8) or cL[1];
                    else
                        bb := 0;
                end;

                // blend with previous color there
                bb := (aa and $FEFEFF >> 1) + (bb and $FEFEFF >> 1);
            end
			else
			begin
                bb := (r << 16) or (g << 8) or b;
            end;

            case Format of
                CRT_PIX_FORMAT_RGB,
                CRT_PIX_FORMAT_RGBA:
				begin
                    cL[0] := (bb >> 16) and $FF;
                    cL[1] := (bb >>  8) and $FF;
                    cL[2] := (bb >>  0) and $FF;
				end;
                CRT_PIX_FORMAT_BGR,
                CRT_PIX_FORMAT_BGRA:
				begin
                    cL[0] := (bb >>  0) and $FF;
                    cL[1] := (bb >>  8) and $FF;
                    cL[2] := (bb >> 16) and $FF;
				end;
                CRT_PIX_FORMAT_ARGB:
				begin
                    cL[1] := (bb >> 16) and $FF;
                    cL[2] := (bb >>  8) and $FF;
                    cL[3] := (bb >>  0) and $FF;
				end;
                CRT_PIX_FORMAT_ABGR:
				begin
                    cL[1] := (bb >>  0) and $FF;
                    cL[2] := (bb >>  8) and $FF;
                    cL[3] := (bb >> 16) and $FF;
				end;
            end;

            Inc(cL, bpp);
			Inc(pos, dx);
        end;

        // duplicate extra lines
		for s := line_beg+1 to line_end-Scanlines-1 do
			Move(output[(s-1) * pitch], output[s * pitch], pitch);
    end;
end;


end.

