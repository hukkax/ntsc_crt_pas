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
unit ntsc_crt_base;

{$MODE DELPHI}{$H+}
{$POINTERMATH ON}

{.$DEFINE USE_CONVOLUTION} // TODO
{.$DEFINE CRT_CC_5_SAMPLES}

interface

uses
	Classes, SysUtils;

type
	TCRTPixelFormat = (
		CRT_PIX_FORMAT_RGB,   // 3 bytes per pixel [R,G,B,R,G,B,R,G,B...]
		CRT_PIX_FORMAT_BGR,   // 3 bytes per pixel [B,G,R,B,G,R,B,G,R...]
		CRT_PIX_FORMAT_ARGB,  // 4 bytes per pixel [A,R,G,B,A,R,G,B...]
		CRT_PIX_FORMAT_RGBA,  // 4 bytes per pixel [R,G,B,A,R,G,B,A...]
		CRT_PIX_FORMAT_ABGR,  // 4 bytes per pixel [A,B,G,R,A,B,G,R...]
		CRT_PIX_FORMAT_BGRA   // 4 bytes per pixel [B,G,R,A,B,G,R,A...]
	);

const
	{$IFDEF CRT_CC_5_SAMPLES}
	CRT_CC_SAMPLES = 5;
	{$ELSE}
	CRT_CC_SAMPLES = 4;
	{$ENDIF}

	HISTLEN = 3;
	HISTOLD = HISTLEN - 1;      // oldest entry
	HISTNEW = 0;                // newest entry
	EQ_P    = 16;               // if changed, the gains will need to be adjusted
	EQ_R    = 1 shl (EQ_P - 1); // rounding

	{$IFDEF USE_CONVOLUTION}
	USE_7_SAMPLE_KERNEL = 1;
	USE_6_SAMPLE_KERNEL = 0;
	USE_5_SAMPLE_KERNEL = 0;
	{$ENDIF}

// ************************************************************************************************
// Filters
// ************************************************************************************************

type
	TEQF = record
	private
		{$IFDEF USE_CONVOLUTION}
		h: array[0..6] of Integer;
		{$ELSE}
		// three band equalizer
		lf, hf: Integer; // fractions
		g: array [0..2] of Integer; // gains
		fL, fH: array [0..3] of Integer;
		h: array [0..HISTLEN-1] of Integer; // history
		{$ENDIF}
	public
		procedure Init(f_lo, f_hi, rate, g_lo, g_mid, g_hi: Integer);
		procedure Reset;
		function  EQF(s: Integer): Integer;
	end;

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

		// keep track of sync over frames
		HSync, VSync: Integer;

		// faster color carrier convergence
		ccf: array of array of Integer;

		// seed for the 'random' noise
		randseed: Integer;

		// CRT input, can be noisy
		analog, inp: array of Int8;

		// factor to stretch img vertically onto the output img TODO
		v_fac: Cardinal;

		// interlaced modes only
		field:            Integer;  // 0 = even, 1 = odd
		frame:            Integer;  // 0 = even, 1 = odd

		xoffset:     Word;    // x offset in sample space. 0 is minimum value
		yoffset:     Word;    // y offset in # of lines. 0 is minimum value

		L_FREQ, Y_FREQ, I_FREQ, Q_FREQ: Cardinal;

		// 0 = vertical  chroma (228.0 chroma clocks per line)
		// 1 = checkered chroma (227.5 chroma clocks per line)
		CRT_CHROMA_PATTERN: Byte;

		CRT_CC_LINE: Word;

		CRT_CB_FREQ:    Byte; // in general, increasing CRT_CB_FREQ reduces blur and bleed
		CRT_HRES:       Word; // horizontal resolution
		CRT_VRES:       Word; // vertical resolution
		CRT_INPUT_SIZE: Cardinal;

		CRT_TOP:        Word; // first line with active video
		CRT_BOT:        Word; // final line with active video
		CRT_LINES:      Word; // number of active video lines

		//CRT_CC_SAMPLES: Byte; // samples per chroma period (samples per 360 deg)
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

		// internal state
		initialized:      Boolean;

		procedure DoInit; virtual;
	public
		Width,
		Height:   Word;            // output width/height

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

		DoVSync:      Boolean;
		DoHSync:      Boolean;
		DoBloom:      Boolean;
		DoBlend:      Boolean; // blend new field onto previous image?

		// VHS
		DoAberration: Boolean;
		DoVHSNoise:   Boolean; // want noise at the bottom of the frame?

		constructor Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer); virtual;
		destructor  Destroy; override;

		procedure Reset; virtual;
		procedure Resize(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer); virtual;
		procedure OptionsChanged; virtual;

		procedure Modulate; virtual; abstract;
		procedure Demodulate; virtual;
		procedure ProcessFrame(Buffer: Pointer); virtual;
	end;


	function  POSMOD(x, n: Integer): Integer; inline;
	function  sintabil8(n: Integer): Integer;
	procedure crt_sincos14(out s: Integer; out c: Integer; n: Integer);
	function  crt_bpp4fmt(Format: TCRTPixelFormat): Integer;


implementation


const
	// significant points on sine wave (15-bit)
	sigpsin15: array[0..17] of Integer = (
		$0000,
		$0c88, $18f8, $2528, $30f8, $3c50, $4718, $5130, $5a80,
		$62f0, $6a68, $70e0, $7640, $7a78, $7d88, $7f60, $8000,
		$7f60
	);


// ************************************************************************************************
// Utility
// ************************************************************************************************

// fixed point sin/cos
const
	T14_2PI  = 16384;
	T14_MASK = T14_2PI - 1;
	T14_PI   = T14_2PI div 2;

// ensure negative values for x get properly modulo'd
function POSMOD(x, n: Integer): Integer; inline;
begin
	Result := (x mod (n) + n) mod n;
end;

function sintabil8(n: Integer): Integer;
var
	f, i, a, b: Integer;
begin
	// looks scary but if you don't change T14_2PI
	// it won't cause out of bounds memory reads
	f := n and $FF;
	i := n >> 8 and $FF;
	a := sigpsin15[i];
	b := sigpsin15[i+1];

	Result := a + SarLongint((b - a) * f, 8);
end;

// 14-bit interpolated sine/cosine
procedure crt_sincos14(out s: Integer; out c: Integer; n: Integer);
var
	h: Integer;
begin
	n := n and T14_MASK;
	h := n and ((T14_2PI >> 1) - 1);

	if h > ((T14_2PI >> 2) - 1) then
	begin
		c := -sintabil8(h - (T14_2PI >> 2));
		s := +sintabil8((T14_2PI >> 1) - h);
	end
	else
	begin
		c := sintabil8((T14_2PI >> 2) - h);
		s := sintabil8(h);
	end;
	if n > ((T14_2PI >> 1) - 1) then
	begin
		c := -c;
		s := -s;
	end;
end;

// Get the bytes per pixel for a certain TCRTPixelFormat
// returns 0 if the specified format does not exist
//
function crt_bpp4fmt(Format: TCRTPixelFormat): Integer;
begin
	case Format of
		CRT_PIX_FORMAT_RGB,
		CRT_PIX_FORMAT_BGR:
			Result := 3;
		CRT_PIX_FORMAT_ARGB,
		CRT_PIX_FORMAT_RGBA,
		CRT_PIX_FORMAT_ABGR,
		CRT_PIX_FORMAT_BGRA:
			Result := 4;
		else
			Result := 0;
	end;
end;

// ************************************************************************************************
// TEQF
// ************************************************************************************************

// f_lo - low cutoff frequency
// f_hi - high cutoff frequency
// rate - sampling rate
// g_lo, g_mid, g_hi - gains
//
procedure TEQF.Init(f_lo, f_hi, rate, g_lo, g_mid, g_hi: Integer);
var
	sn, cs: Integer;
begin
	Reset;

	g[0] := g_lo;
	g[1] := g_mid;
	g[2] := g_hi;

	crt_sincos14(sn, cs, T14_PI * f_lo div rate);
	if EQ_P >= 15 then
		lf := 2 * (sn << (EQ_P - 15))
	else
		lf := 2 * (sn >> (15 - EQ_P));

	crt_sincos14(sn, cs, T14_PI * f_hi div rate);
	if EQ_P >= 15 then
		hf := 2 * (sn << (EQ_P - 15))
	else
		hf := 2 * (sn >> (15 - EQ_P));
end;

procedure TEQF.Reset;
var
	i: Integer;
begin
	{$IFNDEF USE_CONVOLUTION}
	for i := 0 to High(fL) do
	begin
		fL[i] := 0;
		fH[i] := 0;
	end;
	{$ENDIF}
	for i := 0 to High(h) do
		h[i] := 0;
end;

(*
function TEQF.EQF(s: Integer): Integer;
var
	i, h: ^Integer;
begin
	h := f.h;
	for i := 6 downto 1 do
		h[i] := h[i-1];
	h[0] := s;

	{$IF USE_7_SAMPLE_KERNEL}
	{ index : 0 1 2 3 4 5 6 }
	{ weight: 1 4 7 8 7 4 1 }
	Result := (s + h[6] + ((h[1] + h[5]) * 4) + ((h[2] + h[4]) * 7) + (h[3] * 8)) >> 5;
	{$ELSIF USE_6_SAMPLE_KERNEL}
	{ index : 0 1 2 3 4 5 }
	{ weight: 1 3 4 4 3 1 }
	Result := (s + h[5] + 3 * (h[1] + h[4]) + 4 * (h[2] + h[3])) >> 4;
	{$ELSIF USE_5_SAMPLE_KERNEL}
	{ index : 0 1 2 3 4 }
	{ weight: 1 2 2 2 1 }
	Result := (s + h[4] + ((h[1] + h[2] + h[3])  shl  1)) >> 3;
	{$ELSE}
	{ index : 0 1 2 3 }
	{ weight: 1 1 1 1 }
	Result := (s + h[3] + h[1] + h[2]) >> 2;
	{$ENDIF}
end;
*)

function TEQF.EQF(s: Integer): Integer;
var
	i: Integer;
	r: array [0..2] of Integer;
begin
	{$R-}
	fL[0] += SarLongint(lf * (s - fL[0]) + EQ_R, EQ_P);
	fH[0] += SarLongint(hf * (s - fH[0]) + EQ_R, EQ_P);

	for i := 1 to 3 do
	begin
		fL[i] += SarLongint(lf * (fL[i-1] - fL[i]) + EQ_R, EQ_P);
		fH[i] += SarLongint(hf * (fH[i-1] - fH[i]) + EQ_R, EQ_P);
	end;

	r[0] := fL[3];
	r[1] := fH[3] - fL[3];
	r[2] := h[HISTOLD] - fH[3];

	for i := 0 to 2 do
		r[i] := SarLongint(r[i] * g[i], EQ_P);

	for i := HISTOLD downto 1 do
		h[i] := h[i-1];

	h[HISTNEW] := s;

	Result := r[0] + r[1] + r[2];
end;

// ************************************************************************************************
// TNTSCCRTBase
// ************************************************************************************************

procedure TNTSCCRTBase.ProcessFrame(Buffer: Pointer);
begin
	Data := Buffer;
	if Data = nil then Exit;

	Modulate;
	Demodulate;

	if not Progressive then
	begin
		field := field xor 1;
		Modulate;
		Demodulate;
		frame := frame xor 1; // a frame is two fields
	end;
end;

// Updates the output image parameters
// * w   - width of the output image
// * h   - height of the output image
// * f   - format of the output image
// * out - pointer to output image data
//
procedure TNTSCCRTBase.Resize(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer);
begin
	Width  := aWidth;
	Height := aHeight;
	Format := aFormat;
	output := Buffer;
end;

// Resets the CRT settings back to their defaults
//
procedure TNTSCCRTBase.Reset;
begin
	Hue         := 3;
	Saturation  := 75;
	Brightness  := 0;
	Contrast    := 180;
	Black_point := 0;
	White_point := 100;
	HSync := 0;
	VSync := 0;

	Stretch := True;
	Scanlines := 0;
	Noise := 5;
	Monochrome := False;
	Progressive := True;
	DoBlend := False;
	DoVSync := False;
	DoHSync := False;
	DoBloom := False;
	DoAberration := False;
	DoVHSNoise := False;

	if initialized then
		OptionsChanged;
end;

procedure TNTSCCRTBase.OptionsChanged;

	// kilohertz to line sample conversion
	function kHz2L(kHz: Integer): Integer;
	begin
		if L_FREQ > 0.0 then
			Result := Trunc((CRT_HRES * (kHz * 100) / L_FREQ))
		else
			Result := 0;
	end;

begin
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

// Initializes the library. Sets up filters.
// * Width  - width of the output image
// * Height - height of the output image
// * Format - format of the output image
// * Buffer - pointer to output image data
//
constructor TNTSCCRTBase.Create(aWidth, aHeight: Word; aFormat: TCRTPixelFormat; Buffer: Pointer);

	// convert nanosecond offset to its corresponding point on the sampled line
	function ns2pos(ns: Integer): Integer; inline;
	begin
		Result := ns * CRT_HRES div LINE_ns;
	end;

begin
	inherited Create;

	initialized := False;

	Reset;

	CRT_CHROMA_PATTERN := 1;
	CRT_VRES    := 262; // vertical resolution
	CRT_CB_FREQ := 4; // carrier frequency relative to sample rate
	CRT_CC_VPER := 1;
	CB_CYCLES := 10;
	CRT_HSYNC_THRESH := 4;
	CRT_VSYNC_THRESH := 94;

	DoInit;

	// starting points for all the different pulses
	FP_BEG    := ns2pos(0);
	SYNC_BEG  := ns2pos(FP_ns);
	BW_BEG    := ns2pos(FP_ns + SYNC_ns);
	CB_BEG    := ns2pos(FP_ns + SYNC_ns + BW_ns);
	BP_BEG    := ns2pos(FP_ns + SYNC_ns + BW_ns + CB_ns);
	AV_BEG    := ns2pos(HB_ns);
	AV_LEN    := ns2pos(AV_ns);

	{if WHITE_LEVEL = 0 then} WHITE_LEVEL := 100;
	{if BURST_LEVEL = 0 then} BURST_LEVEL := 20;
	{if BLACK_LEVEL = 0 then} BLACK_LEVEL := 7;
	{if BLANK_LEVEL = 0 then} BLANK_LEVEL := 0;
	{if SYNC_LEVEL  = 0 then} SYNC_LEVEL  := -40;

	Resize(aWidth, aHeight, aFormat, Buffer);
end;

procedure TNTSCCRTBase.DoInit;
begin
	// chroma clocks (subcarrier cycles) per line
	//  0 = vertical  chroma (228 chroma clocks per line)
	//  1 = checkered chroma (227.5 chroma clocks per line)
	//  2 = sawtooth  chroma (227.3 chroma clocks per line)
	case CRT_CHROMA_PATTERN of
		1: CRT_CC_LINE := 2275;
		2: CRT_CC_LINE := 2273;
		else // this will give the 'rainbow' effect in the famous waterfall scene
		   CRT_CC_LINE := 2280;
	end;

	CRT_HRES       := CRT_CC_LINE * CRT_CB_FREQ div 10; // horizontal resolution
	CRT_INPUT_SIZE := CRT_HRES * CRT_VRES;
	CRT_LINES      := CRT_BOT - CRT_TOP; // number of active video lines

	SetLength(ccf,    CRT_CC_VPER+1, CRT_CC_SAMPLES+1);
	SetLength(analog, CRT_INPUT_SIZE);
	SetLength(inp,    CRT_INPUT_SIZE);
	SetLength(outrec, AV_LEN);

	randseed := 194;
end;

destructor TNTSCCRTBase.Destroy;
begin
	inherited Destroy;
end;

// Demodulates the NTSC signal generated by TCRT.Modulate()
// * noise - the amount of noise added to the signal (0 - inf)
//
procedure TNTSCCRTBase.Demodulate;
label
	found_vsync,
	found_field;
var
	yiqA, yiqB: ^TOutRec;
	sig: PInt8;
	i, j, line, rn: Integer;
	s: Integer = 0;
	field, ratio: Integer;
	ccr: PInteger; // color carrier signal
	//ccr: Cardinal;
	huesn, huecs: Integer;
	xnudge: Integer = -3;
	ynudge: Integer = +3;
	bright: Integer;
	bpp, pitch: Integer;
	prev_e: Integer; // filtered beam energy per scan line
	max_e: Integer;  // approx maximum energy in a scan line
	sn, cs, nn, lnn,
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
	ang, off180, off90,
	peakA, peakB: Integer;
	waveI, waveQ: array [0..CRT_CC_SAMPLES-1] of Integer;
	{$ELSE}
	wave: array [0..CRT_CC_SAMPLES-1] of Integer;
	{$ENDIF}
begin
	{$R-}
	bpp := crt_bpp4fmt(Format);
	if bpp = 0 then Exit;
	pitch := Width * bpp;

	crt_sincos14(huesn, huecs, Trunc(((Hue mod 360) + 33) * 8192 / 180));
	huesn := {%H-}huesn shr 11; // make 4-bit
	huecs := {%H-}huecs shr 11;

	rn := randseed;

	if not DoVSync then
	begin
		// determine field before we add noise,
		// otherwise it's not reliably recoverable
		for i := -CRT_VSYNC_WINDOW to CRT_VSYNC_WINDOW-1 do
		begin
			line := POSMOD(VSync + i, CRT_VRES);
			sig  := @analog[line * CRT_HRES];
			s := 0;
			for j := 0 to CRT_HRES-1 do
			begin
				s += sig[j];
				if s <= (CRT_VSYNC_THRESH * SYNC_LEVEL) then
					goto found_field;
			end;
		end;

found_field:
		// if vsync signal was in second half of line, odd field
		if j > (CRT_HRES div 2) then
			field := 1
		else
			field := 0;
		VSync := -3;
	end;

	if DoVHSNoise then
		line := (Random(8) - 4) + 14;

    for i := 0 to CRT_INPUT_SIZE-1 do
	begin
        nn := noise;
		if DoVHSNoise then
		begin
			rn := Trunc(Random(MaxInt));
			if (i > (CRT_INPUT_SIZE - CRT_HRES * (16 + (Random(20) - 10)))) and
			   (i < (CRT_INPUT_SIZE - CRT_HRES * ( 5 + (Random(8)  -  4)))) then
			begin
				lnn := i * line div CRT_HRES;
				crt_sincos14(sn, cs, lnn * 8192 div 180);
				nn := SarLongint(cs, 8);
			end;
		end
		else
		begin
			rn := 214019 * rn + 140327895;
		end;
        // signal + noise
        s := analog[i] + SarLongint( (( SarLongint(rn, 16) and $FF) - $7F) * nn, 8);
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
					goto found_vsync;
			end;
		end;

found_vsync:
		VSync := line; // vsync found (or gave up) at this line
		// if vsync signal was in second half of line, odd field
		if j > (CRT_HRES div 2) then
			field := 1
		else
			field := 0;
	end;

	if DoBloom then
	begin
		max_e  := (128 + (noise div 2)) * AV_LEN;
		prev_e := 16384 div 8;
	end;

    // ratio of output height to active video lines in the signal
    ratio := (Height << 16) div CRT_LINES;
    ratio := SarLongint(ratio + 32768, 16);
    field := field * (ratio div 2);

    for line := CRT_TOP to CRT_BOT-1 do
	begin
        line_beg := (line - CRT_TOP + 0) * (Height + v_fac) div CRT_LINES + field;
        line_end := (line - CRT_TOP + 1) * (Height + v_fac) div CRT_LINES + field;

        if line_beg >= Height then Continue;
        if line_end >  Height then line_end := Height;

        // Look for horizontal sync.
        // See comment above regarding vertical sync.
        ln  := POSMOD(line + VSync, CRT_VRES) * CRT_HRES;
        sig := @inp[ln + HSync];
        s := 0;
        for i := -CRT_HSYNC_WINDOW to CRT_HSYNC_WINDOW-1 do
		begin
            s += sig[SYNC_BEG + i];
            if s <= (CRT_HSYNC_THRESH * SYNC_LEVEL) then Break;
        end;

		if DoHSync then
			HSync := POSMOD(i + HSync, CRT_HRES)
		else
			HSync := 0;

        xpos := POSMOD(AV_BEG + HSync + xnudge, CRT_HRES);
        ypos := POSMOD(line + VSync + ynudge, CRT_VRES);
        pos  := xpos + ypos * CRT_HRES;
        //ccr  := ypos mod CRT_CC_VPER;
        ccr  := @ccf[ypos mod CRT_CC_VPER, 0];

		{$IFDEF CRT_CC_5_SAMPLES}
		sig := @inp[ln + (HSync - (HSync mod CRT_CC_SAMPLES))];
		{$ELSE}
		sig := @inp[ln + (HSync and (not 3))]; // faster
		{$ENDIF}

        for i := CB_BEG to CB_BEG + (CB_CYCLES * CRT_CB_FREQ) - 1 do
		begin
            //p := ccf[ccr, i mod CRT_CC_SAMPLES]  * 127 div 128; // fraction of the previous
			p :=  ccr[i mod CRT_CC_SAMPLES] * 127 div 128; // fraction of the previous
            n := sig[i];                 // mixed with the new sample
            ccr[i mod CRT_CC_SAMPLES] := p + n;
			//ccf[ccr, i mod CRT_CC_SAMPLES] := p + n;
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
//		dci := ccf[ccr, (phasealign + 1) and 3] - ccf[ccr, (phasealign + 3) and 3];
//		dcq := ccf[ccr, (phasealign + 2) and 3] - ccf[ccr, (phasealign + 0) and 3];

		wave[0] := Trunc(SarLongint((dci * huecs - dcq * huesn), 4) * (Saturation / 20));
		wave[1] := Trunc(SarLongint((dcq * huecs + dci * huesn), 4) * (Saturation / 20));
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
			prev_e := (prev_e * 123 div 128) + (((SarLongint(max_e, 1) - s) << 10) div max_e);
			line_w := (AV_LEN * 112 div 128) + SarLongint(prev_e, 9);

			dx := (line_w << 12) div Width;
			scanL := ((AV_LEN div 2) - (line_w >> 1) + 8) << 12;
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
            s := SarLongint(pos, 12);

            yiqA := @outrec[s];
            yiqB := @outrec[s+1];

            // interpolate between samples if needed
            y := SarLongint(yiqA.y * LT,  2) + SarLongint(yiqB.y * RT,  2);
            i := SarLongint(yiqA.i * LT, 14) + SarLongint(yiqB.i * RT, 14);
            q := SarLongint(yiqA.q * LT, 14) + SarLongint(yiqB.q * RT, 14);

//			i := 0;
//			q := ((yiqA.y * LT) >> 14) + ((yiqB.y * RT) >> 14); // Y but >> 14

            // YIQ to RGB
            r := SarLongint(y + 3879 * i + 2556 * q, 12) * Contrast >> 8;
            g := SarLongint(y - 1126 * i - 2605 * q, 12) * Contrast >> 8;
            b := SarLongint(y - 4530 * i + 7021 * q, 12) * Contrast >> 8;

            if r < 0   then r := 0
			else
            if r > 255 then r := 255;
            if g < 0   then g := 0
			else
            if g > 255 then g := 255;
            if b < 0   then b := 0
			else
            if b > 255 then b := 255;

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
                bb := (((aa and $FEFEFF) >> 1) + ((bb and $FEFEFF) >> 1));
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

