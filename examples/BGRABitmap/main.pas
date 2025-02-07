unit Main;

{$I ../../ntsc_crt_options.inc}

interface

uses
	Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, LCLType, ExtDlgs,
	BGRABitmapTypes, BGRABitmap, BGRAVirtualScreen;

type
	TMainForm = class(TForm)
		Timer: TTimer;
		pb: TBGRAVirtualScreen;
		OpenDialog: TOpenPictureDialog;

		procedure FormShow(Sender: TObject);
		procedure FormDestroy(Sender: TObject);
		procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
		procedure TimerTimer(Sender: TObject);
		procedure pbRedraw(Sender: TObject; Bitmap: TBGRABitmap);
	private
	public
		function LoadImage(Filename: String): Boolean;
	end;

var
	MainForm: TMainForm;

implementation

{$R *.lfm}

uses
	ntsc_crt_common, ntsc_crt_base, ntsc_crt;

var
	CRT: TNTSCCRT;

	image, output: TBGRABitmap;

	// OSD
	MessageTextTimer: Integer;
	MessageText: String;
	Processing: Boolean = False;

const
	Increments: array[Boolean] of Integer = ( -1, +1 );
	EnabledStr: array[Boolean] of String  = ( 'Off', 'On' );


{ TMainForm }

procedure TMainForm.FormShow(Sender: TObject);
begin
	OnShow := nil;

	pb.Font.Size := 20;
	pb.Font.Color := clWhite;

	CRT := TNTSCCRT.Create;

	CRT.VHSMode := VHS_EP;
	CRT.DoAberration := True;
	CRT.DoVHSNoise := True;

	CRT.Stretch := True;
	CRT.Monochrome := False;
	CRT.Progressive := False;
	CRT.Noise := 0;
	CRT.DoBlend := False;

	CRT.DoVSync := True;
	CRT.DoHSync := True;
	CRT.DoBloom := False;

	if not LoadImage('../ti.png') then
		Close;
end;

function TMainForm.LoadImage(Filename: String): Boolean;
var
	W, H: Integer;
	tmp: TBGRABitmap;
begin
	Result := False;

	if Filename = '' then
	begin
		Timer.Enabled := False;
		if OpenDialog.Execute then
			Filename := OpenDialog.FileName
		else
		begin
			Timer.Enabled := (image <> nil);
			Exit;
		end;
	end;

	if not FileExists(Filename) then
	begin
		ShowMessage('File not found: ' + Filename);
		Exit;
	end;

	Timer.Enabled := False;

	tmp := TBGRABitmap.Create;
	tmp.LoadFromFile(Filename);
	W := tmp.Width;
	H := tmp.Height;
	if (W < 100) or (H < 100) then
	begin
		tmp.Free;
		Timer.Enabled := (image <> nil);
		Exit;
	end;

	image.Free;
	output.Free;

	image := TBGRABitmap.Create;
	image.LineOrder := riloTopToBottom; // important - otherwise image might render upside down
	image.SetSize(W, H);
	image.Fill(BGRABlack);
	image.PutImage(0, 0, tmp, dmSet);
	tmp.Free;

	output := TBGRABitmap.Create(W, H, BGRABlack);
	output.LineOrder := riloTopToBottom;

	CRT.Resize(W, H, CRT_PIX_FORMAT_BGRA, output.Data);

	ClientWidth := W;
	ClientHeight := H;
	pb.SetBounds(0, 0, W, H);
	MoveToDefaultPosition; // recenter window

	Result := True;
	Timer.Enabled := True;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
	Timer.Enabled := False;
	CRT.Free;
	image.Free;
	output.Free;
end;

procedure TMainForm.TimerTimer(Sender: TObject);
begin
	if Processing then Exit;

	Processing := True;

	CRT.ProcessFrame(image.Data);
	pb.RedrawBitmap;

	Processing := False;
end;

procedure TMainForm.pbRedraw(Sender: TObject; Bitmap: TBGRABitmap);
var
	X, Y, H: Integer;
	S: String;
begin
	pb.Bitmap.PutImage(0, 0, output, dmSet);

	if MessageTextTimer > 0 then
	begin
		pb.Bitmap.TextOut(20, 20, MessageText, BGRAWhite);
		Dec(MessageTextTimer);
	end;

	{$IFDEF MEASURE_TIMING}
	X := image.Width - 80;
	Y := 24;
	H := pb.Font.Size + 10;
	S := Format('%.2f', [CRT.Timing.Modulation]);
	pb.Bitmap.TextOut(X, Y+(H*0), S, BGRAWhite);
	S := Format('%.2f', [CRT.Timing.Demodulation]);
	pb.Bitmap.TextOut(X, Y+(H*1), S, BGRAWhite);
	S := Format('%.2f', [CRT.Timing.Modulation + CRT.Timing.Demodulation]);
	pb.Bitmap.TextOut(X, Y+(H*2), S, BGRAWhite);
	if (CRT.Timing.Modulation + CRT.Timing.Demodulation) > 0 then
	begin
		S := Format('%.2f FPS', [1000 / (CRT.Timing.Modulation + CRT.Timing.Demodulation)]);
		pb.Bitmap.TextOut(X-40, pb.Height-H-5, S, BGRAWhite);
	end;
	{$ENDIF}
end;

procedure OSD(const S: String);
begin
	MessageTextTimer := 90;
	MessageText := S;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
	{$R-}
	while Processing do;

	case Key of

		// exit
		VK_ESCAPE:
			Close;

		// toggle between original and processed image
		VK_SPACE:
			Timer.Enabled := not Timer.Enabled;

		// load in a new image
		VK_RETURN:
		begin
		{
			Timer.Enabled := False;
			if OpenDialog.Execute then
				LoadImage(OpenDialog.FileName)
			else
				Timer.Enabled := True;
		}
			LoadImage('');
		end;

		// toggle monochrome/color mode
		VK_M:
		begin
			CRT.Monochrome := not CRT.Monochrome;
			if CRT.Monochrome then
				OSD('Monochrome')
			else
				OSD('Color');
		end;

		// toggle progressive/interlaced
		VK_P:
		begin
			CRT.Progressive := not CRT.Progressive;
			if CRT.Progressive then
				OSD('Progressive')
			else
				OSD('Interlaced');
		end;

		// toggle blending
		VK_B:
		begin
			CRT.DoBlend := not CRT.DoBlend;
			OSD('Blending: ' + EnabledStr[CRT.DoBlend]);
		end;

		// toggle bloom
		VK_L:
		begin
			CRT.DoBloom := not CRT.DoBloom;
			OSD('Bloom: ' + EnabledStr[CRT.DoBloom]);
		end;

		// toggle chromatic aberration
		VK_A:
		begin
			CRT.DoAberration := not CRT.DoAberration;
			OSD('Aberration: ' + EnabledStr[CRT.DoAberration]);
		end;

		// toggle vertical sync
		VK_V:
		begin
			CRT.DoVSync := not CRT.DoVSync;
			OSD('VSync: ' + EnabledStr[CRT.DoVSync]);
		end;

		// toggle horizontal sync
		VK_H:
		begin
			CRT.DoHSync := not CRT.DoHSync;
			OSD('HSync: ' + EnabledStr[CRT.DoHSync]);
		end;

		// toggle VHS noise
		VK_N:
		begin
			CRT.DoVHSNoise := not CRT.DoVHSNoise;
			OSD('VHS noise: ' + EnabledStr[CRT.DoVHSNoise]);
		end;

		// toggle scanlines
		VK_S:
		begin
			CRT.Scanlines := 1 - CRT.Scanlines;
			OSD('Scanlines: ' + EnabledStr[CRT.Scanlines > 0]);
		end;

		// turn off VHS mode
		VK_0:
		begin
			CRT.VHSMode := VHS_NONE;
			OSD('VHS mode: Off');
		end;

		// set VHS mode to normal quality
		VK_1:
		begin
			CRT.VHSMode := VHS_SP;
			OSD('VHS mode: SP');
		end;

		// set VHS mode to medium (long play) quality
		VK_2:
		begin
			CRT.VHSMode := VHS_LP;
			OSD('VHS mode: LP');
		end;

		// set VHS mode to worst (extended play) quality
		VK_3:
		begin
			CRT.VHSMode := VHS_EP;
			OSD('VHS mode: EP');
		end;

		VK_C:
		begin
			CRT.ChromaPattern := CRT.ChromaPattern + 1;
			OSD('Chroma pattern: ' + IntToStr(CRT.ChromaPattern));
		end;

		// control noise amount
		VK_ADD, VK_SUBTRACT:
		begin
			CRT.Noise := CRT.Noise + Increments[Key = VK_ADD];
			OSD('Noise: ' + IntToStr(CRT.Noise));
		end;

		// control saturation amount
		VK_UP, VK_DOWN:
		begin
			CRT.Saturation := CRT.Saturation + Increments[Key = VK_UP];
			OSD('Saturation: ' + IntToStr(CRT.Saturation));
		end;

		// control hue
		VK_RIGHT, VK_LEFT:
		begin
			CRT.Hue := CRT.Hue + Increments[Key = VK_RIGHT];
			OSD('Hue: ' + IntToStr(CRT.Hue));
		end;

	end;

	if not Timer.Enabled then
		pb.RedrawBitmap;
end;


end.

