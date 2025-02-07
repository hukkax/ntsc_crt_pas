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
unit ntsc_crt_common;

{$I ntsc_crt_options.inc}

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
	BoolToVal: array [Boolean] of Integer = ( 0, 1 );

	crt_bpp4fmt: array [TCRTPixelFormat] of Byte = (
		3, // CRT_PIX_FORMAT_RGB
		3, // CRT_PIX_FORMAT_BGR
		4, // CRT_PIX_FORMAT_ARGB
		4, // CRT_PIX_FORMAT_RGBA
		4, // CRT_PIX_FORMAT_ABGR
		4  // CRT_PIX_FORMAT_BGRA
	);

const
	// samples per chroma period (samples per 360 deg)
	{$IFDEF CRT_CC_5_SAMPLES}
	CRT_CC_SAMPLES = 5;
	{$ELSE}
	CRT_CC_SAMPLES = 4;
	{$ENDIF}

	{$IFDEF USE_CONVOLUTION}
	CONV_SAMPLE_KERNEL_SIZE = 7; // 5,6,7,other
	{$ELSE}
	HISTLEN = 3;
	HISTOLD = HISTLEN - 1;      // oldest entry
	HISTNEW = 0;                // newest entry
	EQ_P    = 16;               // if changed, the gains will need to be adjusted
	EQ_R    = 1 shl (EQ_P - 1); // rounding
	{$ENDIF}

	// fixed point sin/cos
	T14_2PI  = 16384;
	T14_MASK = T14_2PI - 1;
	T14_PI   = T14_2PI div 2;

	// significant points on sine wave (15-bit)
	sigpsin15: array[0..17] of Integer = (
		$0000,
		$0c88, $18f8, $2528, $30f8, $3c50, $4718, $5130, $5a80,
		$62f0, $6a68, $70e0, $7640, $7a78, $7d88, $7f60, $8000,
		$7f60
	);

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

	function  ClampToByte(const Value: Integer): Integer;
	function  POSMOD(x, n: Integer): Integer; inline;
	function  sintabil8(n: Integer): Integer; inline;
	procedure crt_sincos14(out s: Integer; out c: Integer; n: Integer);
	function  crt_sin14(n: Integer): Integer; inline;
	function  crt_cos14(n: Integer): Integer; inline;


implementation


// ************************************************************************************************
// Utility
// ************************************************************************************************

{$R-}{$Q-}  // switch off overflow and range checking


// clamp values to byte range (source: Graphics32)
function ClampToByte(const Value: Integer): Integer;
{$IFDEF USENATIVECODE}
begin
	if Value > 255 then
		Result := 255
	else
	if Value < 0 then
		Result := 0
	else
		Result := Value;
{$ELSE}
{$IFDEF FPC} assembler; nostackframe; {$ENDIF}
asm
	{$IFDEF TARGET_x64}
        // in x64 calling convention parameters are passed in ECX, EDX, R8 & R9
        MOV     EAX,ECX
	{$ENDIF}
        TEST    EAX,$FFFFFF00
        JNZ     @1
        RET
@1:     JS      @2
        MOV     EAX,$FF
        RET
@2:     XOR     EAX,EAX
	{$ENDIF}
end;

// ensure negative values for x get properly modulo'd
function POSMOD(x, n: Integer): Integer;
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

// 14-bit interpolated sine
function crt_sin14(n: Integer): Integer;
var
	h: Integer;
begin
	n := n and T14_MASK;
	h := n and ((T14_2PI >> 1) - 1);
	if h > ((T14_2PI >> 2) - 1) then
		Result := sintabil8((T14_2PI >> 1) - h)
	else
		Result := sintabil8(h);
	if n > ((T14_2PI >> 1) - 1) then
		Result := -Result;
end;

// 14-bit interpolated cosine
function crt_cos14(n: Integer): Integer;
var
	h: Integer;
begin
	n := n and T14_MASK;
	h := n and ((T14_2PI >> 1) - 1);
	if h > ((T14_2PI >> 2) - 1) then
		Result := -sintabil8(h - (T14_2PI >> 2))
	else
		Result := +sintabil8((T14_2PI >> 2) - h);
	if n > ((T14_2PI >> 1) - 1) then
		Result := -Result;
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
{$IFNDEF USE_CONVOLUTION}
var
	sn, cs: Integer;
{$ENDIF}
begin
	Reset;

	{$IFNDEF USE_CONVOLUTION}
	g[0] := g_lo;
	g[1] := g_mid;
	g[2] := g_hi;

	crt_sincos14(sn, cs, T14_PI * f_lo div rate);

	{$IF EQ_P >= 15}
	lf := 2 * (sn << (EQ_P - 15));
	{$ELSE}
	lf := 2 * (sn >> (15 - EQ_P));
	{$ENDIF}

	crt_sincos14(sn, cs, T14_PI * f_hi div rate);

	{$IF EQ_P >= 15}
	hf := 2 * (sn << (EQ_P - 15));
	{$ELSE}
	hf := 2 * (sn >> (15 - EQ_P));
	{$ENDIF}
	{$ENDIF}
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

function TEQF.EQF(s: Integer): Integer;
{$IFDEF USE_CONVOLUTION}
var
	i: Integer;
begin
	for i := 6 downto 1 do
		h[i] := h[i-1];
	h[0] := s;

	{$IF CONV_SAMPLE_KERNEL_SIZE=7}
	{ index : 0 1 2 3 4 5 6 }
	{ weight: 1 4 7 8 7 4 1 }
	Result := (s + h[6] + ((h[1] + h[5]) * 4) + ((h[2] + h[4]) * 7) + (h[3] * 8)) >> 5;
	{$ELSEIF CONV_SAMPLE_KERNEL_SIZE=6}
	{ index : 0 1 2 3 4 5 }
	{ weight: 1 3 4 4 3 1 }
	Result := (s + h[5] + 3 * (h[1] + h[4]) + 4 * (h[2] + h[3])) >> 4;
	{$ELSEIF CONV_SAMPLE_KERNEL_SIZE=5}
	{ index : 0 1 2 3 4 }
	{ weight: 1 2 2 2 1 }
	Result := (s + h[4] + ((h[1] + h[2] + h[3])  shl  1)) >> 3;
	{$ELSE}
	{ index : 0 1 2 3 }
	{ weight: 1 1 1 1 }
	Result := (s + h[3] + h[1] + h[2]) >> 2;
	{$ENDIF}
{$ELSE}
var
	i: Integer;
	r: array [0..2] of Integer;
begin
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
{$ENDIF}
end;


end.

