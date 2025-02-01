unit ntsc_crt_snes;

{$MODE DELPHI}{$H+}

interface

uses
	Classes, SysUtils,
	ntsc_crt;

type
	TNTSCCRT_SNES = class(TNTSCCRT)
	protected
	public
		dot_crawl_offset: 0..3;

		procedure Modulate; override;
	end;


implementation


procedure TNTSCCRT_SNES.Modulate;
begin
	//
end;


end.

