{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit NTSC_CRT_pkg;

{$warn 5023 off : no warning about unused units}
interface

uses
    ntsc_crt, ntsc_crt_base, ntsc_crt_nes, ntsc_crt_snes, TimeMeasurer, LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage( 'NTSC_CRT_pkg', @Register);
end.
