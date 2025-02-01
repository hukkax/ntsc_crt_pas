unit Main;

{$mode Delphi}{$H+}

interface

uses
	Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, LCLType,
	GR32, GR32_Image;

type
	TMainForm = class(TForm)
		pb: TPaintBox32;
		Timer: TTimer;
		procedure FormShow(Sender: TObject);
		procedure FormDestroy(Sender: TObject);
		procedure TimerTimer(Sender: TObject);
		procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
	private

	public

	end;

var
	MainForm: TMainForm;

implementation

{$R *.lfm}

uses
	ntsc_crt_base in '../../ntsc_crt_base.pas',
	ntsc_crt in '../../ntsc_crt.pas';

var
	CRT: TNTSCCRT;
	image, output: TBitmap32;

	// OSD
	MessageTextTimer: Integer;
	MessageText: String;

const
	Increments: array[Boolean] of Integer = ( -1, +1 );
	EnabledStr: array[Boolean] of String  = ( 'Off', 'On' );


{ TMainForm }

procedure TMainForm.FormShow(Sender: TObject);
var
	W, H: Integer;
begin
	OnShow := nil;

	image := TBitmap32.Create;

	image.LoadFromFile('../dog.png');
//	image.LoadFromFile('../colorspace.png');

	W := image.Width;
	H := image.Height;
	pb.SetBounds(0, 0, W, H);
	pb.Buffer.Draw(0, 0, image);
	pb.Buffer.Font.Size := 20;
	pb.Buffer.Font.Color := clWhite;

	output := TBitmap32.Create(W, H);

	CRT := TNTSCCRT.Create(W, H, CRT_PIX_FORMAT_RGBA, @output.Bits[0]);

	CRT.Stretch := True;
	CRT.Monochrome := False;
	CRT.Progressive := False;
	CRT.Scanlines := 0;
	CRT.Noise := 9;
	CRT.DoBlend := False;
	CRT.DoVSync := True;
	CRT.DoHSync := True;
	CRT.DoBloom := False;
	CRT.DoAberration := True;
	CRT.DoVHSNoise := True;

	Timer.Enabled := True;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
	CRT.Free;
	image.Free;
	output.Free;
end;

procedure TMainForm.TimerTimer(Sender: TObject);
begin
	CRT.ProcessFrame(@image.Bits[0]);

	pb.Buffer.Draw(0, 0, output);

	if MessageTextTimer > 0 then
	begin
		pb.Buffer.Textout(20, 20, MessageText);
		Dec(MessageTextTimer);
	end;

	pb.Invalidate;
end;

procedure OSD(const S: String);
begin
	MessageTextTimer := 90;
	MessageText := S;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
	case Key of

		// exit
		VK_ESCAPE:
			Close;

		// toggle between original and processed image
		VK_SPACE:
		begin
			Timer.Enabled := not Timer.Enabled;
			if not Timer.Enabled then
			begin
				pb.Buffer.Draw(0, 0, image);
				pb.Invalidate;
			end;
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
		VK_L:
		begin
			CRT.DoBlend := not CRT.DoBlend;
			OSD('Blending: ' + EnabledStr[CRT.DoBlend]);
		end;

		// toggle bloom
		VK_B:
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
end;


end.

