{$MODE DELPHI}{$H+}
{$POINTERMATH ON}

{$IF DEFINED(CPUX86_64)}
	{$DEFINE TARGET_x64}
	{$ASMMODE INTEL}
{$ENDIF}

// disable assembly optimizations
{.$DEFINE USENATIVECODE}

// ============================================================================
// Options
// ============================================================================

// convolution is much faster but the EQ looks softer, more authentic, and more analog
{$DEFINE USE_CONVOLUTION}

// TODO
{.$DEFINE CRT_CC_5_SAMPLES}

// measure how long (de)modulation takes using TimeMeasurer.pas
{$DEFINE MEASURE_TIMING}

