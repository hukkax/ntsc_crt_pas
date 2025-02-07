program Demo_SDL2;

{$I ../../ntsc_crt_options.inc}

uses
	{$IFDEF UNIX}cthreads,{$ENDIF}
	Classes, Types, Graphics,
	SDL2, SDL2_image,
	ntsc_crt_common, ntsc_crt_base, ntsc_crt;

type
	TPixelData = array of Cardinal;

var
	Window:   PSDL_Window;
	Renderer: PSDL_Renderer;
	Texture:  PSDL_Texture;
	Src, Dst: TPixelData;
	CRT: TNTSCCRT;
	Width, Height: Integer;

function LoadImage(const Filename: String): Boolean;
var
	tmp, bitmap: PSDL_Surface;
	X, Y: Integer;
begin
	Result := False;

	tmp := IMG_Load(PChar(Filename));
	if tmp = nil then
	begin
        writeln(SDL_GetError());
		Halt;
	end;
	// annoying, but the pixel format can be whatever on a loaded image
	bitmap := SDL_ConvertSurfaceFormat(tmp, SDL_PIXELFORMAT_ABGR8888, 0);

	Width  := bitmap.w;
	Height := bitmap.h;

	SetLength(Src, Width*Height);
	SetLength(Dst, Width*Height);

	CRT.Resize(Width, Height, CRT_PIX_FORMAT_RGBA, @Dst[0]);

	// create a buffer with the raw pixel data
	SDL_LockSurface(bitmap);
	for Y := 0 to Height-1 do
	for X := 0 to Width-1 do
	begin
		Src[Y*Width+X] := PCardinal(bitmap.pixels)[Y*Width+X];
	end;
	SDL_UnlockSurface(bitmap);

	SDL_FreeSurface(bitmap);

	if Texture <> nil then
		SDL_DestroyTexture(Texture);
	Texture := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_ABGR8888,
		SDL_TEXTUREACCESS_STREAMING, Width, Height);
	// ignore the alpha channel
	SDL_SetTextureBlendMode(Texture, SDL_BLENDMODE_NONE);
end;

const
	Scale = 1;
var
	event: TSDL_Event;
	QuitFlag: Boolean = False;
begin
    if SDL_Init(SDL_INIT_VIDEO or SDL_INIT_EVENTS) < 0 then
	begin
        writeln(SDL_GetError());
		Halt;
	end;

	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, 'nearest');

	Window := SDL_CreateWindow('NTSC_CRT with SDL2 Test',
		100, 100, Trunc(768*Scale), Trunc(576*Scale), SDL_WINDOW_SHOWN);
	if Window = nil then
	begin
        writeln(SDL_GetError());
		Halt;
	end;

	Renderer := SDL_CreateRenderer(Window, -1, SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);
	if Renderer = nil then
	begin
        writeln(SDL_GetError());
		Halt;
	end;

	IMG_Init(IMG_INIT_PNG);

	SDL_SetWindowPosition(Window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);

	CRT := TNTSCCRT.Create;

	CRT.Stretch := True;
	CRT.Monochrome := False;
	CRT.Progressive := False;
	CRT.Noise := 0;
	CRT.DoBlend := False;
	CRT.DoVSync := True;
	CRT.DoHSync := True;
	CRT.DoBloom := False;
	CRT.VHSMode := VHS_EP;
	CRT.DoAberration := True;
	CRT.DoVHSNoise := True;

	LoadImage('../ti.png');

	while not QuitFlag do
	begin
		// handle keyboard input and window events
		while SDL_PollEvent(@event) <> 0 do
		case event.type_ of
			SDL_KEYDOWN:
				case event.key.keysym.sym of
					SDLK_ESCAPE: QuitFlag := True;
				end;
			SDL_QUITEV: QuitFlag := True;
		end;

		// process an NTSC frame
		CRT.ProcessFrame(@Src[0]);

		// clear output
	    SDL_RenderClear(Renderer);

		// update the texture with latest processed NTSC frame
		SDL_UpdateTexture(Texture, nil, @Dst[0], Width*4);

		// render the texture
		SDL_RenderCopy(Renderer, Texture, nil, nil);

		// to screen
	    SDL_RenderPresent(Renderer);
	end;

	CRT.Free;
	SDL_DestroyRenderer(Renderer);
	SDL_DestroyTexture(Texture);
	SDL_DestroyWindow(Window);
	IMG_Quit;
	SDL_Quit;
end.

