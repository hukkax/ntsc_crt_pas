NTSC/CRT - integer-only NTSC video signal encoding/decoding emulation

Original by EMMIR 2018-2023
Free Pascal port by hukka 2025

Github:  https://github.com/LMP88959/NTSC-CRT
YouTube: https://www.youtube.com/@EMMIR_KC/videos
Discord: https://discord.com/invite/hdYctSmyQJ

TODO:
- implement NES and SNES modes
- test on Delphi
- example projects for SDL2/SDL3/BGRABitmap

USAGE:
  See the examples directory. In short, instantiate the appropriate
  subclass you want (e.g. TNTSCCRT), set its options and give it the
  pointers to the first pixels of the input and output buffers, then
  call the ProcessFrame method for each frame rendered.
