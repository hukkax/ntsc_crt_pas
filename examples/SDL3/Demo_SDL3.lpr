program Demo_SDL3;

{$I ../../ntsc_crt_options.inc}

uses
	{$IFDEF UNIX}cthreads,{$ENDIF}
	Classes, Types, Graphics,
	SDL3, SDL3_image,
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

type
	TPixel = packed record
	case Boolean of
		True:  ( Value: Cardinal );
		False: ( r, g, b, a: Byte );
	end;

function LoadImage(const Filename: String): Boolean;
var
	bitmap: PSDL_Surface;
	X, Y: Integer;
	pixel: TPixel;
begin
	Result := False;

	bitmap := IMG_Load(PChar(Filename));
	if bitmap = nil then
	begin
        SDL_Log(SDL_GetError());
		Halt(SDL_APP_FAILURE);
	end;

	Width  := bitmap.w;
	Height := bitmap.h;

	SetLength(Src, Width*Height);
	SetLength(Dst, Width*Height);

	CRT.Resize(Width, Height, CRT_PIX_FORMAT_RGBA, @Dst[0]);

	if Texture <> nil then
		SDL_DestroyTexture(Texture);
	Texture := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_ABGR8888,
		SDL_TEXTUREACCESS_STREAMING, Width, Height);

	for Y := 0 to Height-1 do
	for X := 0 to Width-1 do
	begin
		SDL_ReadSurfacePixel(bitmap, X, Y, @Pixel.r, @Pixel.g, @Pixel.b, @Pixel.a);
		Src[Y*Width+X] := Pixel.Value;
	end;

	SDL_DestroySurface(bitmap);
end;

const
	Scale = 1.0;
var
	W, H: Integer;
    R: TSDL_FRect;
	event: TSDL_Event;
begin
    if (not SDL_Init(SDL_INIT_VIDEO)) or
	   (not SDL_CreateWindowAndRenderer('NTSC_CRT with SDL3 Test',
			Trunc(768*Scale), Trunc(576*Scale), 0, @Window, @Renderer)) then
	begin
        SDL_Log(SDL_GetError());
		Halt(SDL_APP_FAILURE);
	end;

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

	SDL_SetTextureBlendMode(Texture, SDL_BLENDMODE_NONE);
	SDL_SetRenderDrawColor(Renderer, 255, 0, 0, 255);
	SDL_SetRenderVSync(Renderer, 1);

	while True do
	begin
		// handle keyboard input and window events
		SDL_PollEvent(@event);
		case event._type of
			SDL_EVENT_KEY_DOWN:
			case event.key.key of
				SDLK_ESCAPE:
					Break;
			end;
			SDL_EVENT_QUIT:
				Break;
		end;

	    SDL_GetRenderOutputSize(Renderer, @W, @H);
	    SDL_SetRenderScale(Renderer, Scale, Scale);
	    SDL_GetTextureSize(Texture, @R.w, @R.h);
	    R.x := ((W / Scale) - R.w) / 2;
	    R.y := ((H / Scale) - R.h) / 2;

		// clear output
	    SDL_RenderClear(Renderer);

		// process an NTSC frame from Dst[] to Src[]
		CRT.ProcessFrame(@Src[0]);

		// update the texture with latest processed NTSC frame
		SDL_UpdateTexture(Texture, nil, @Dst[0], Width*4);

		// render the texture
	    SDL_RenderTexture(Renderer, Texture, nil, @R);

		// to screen
	    SDL_RenderPresent(Renderer);
	end;

	CRT.Free;
	SDL_DestroyRenderer(Renderer);
	SDL_Quit;
end.

