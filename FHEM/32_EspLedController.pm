# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)

package main;
use strict;
use warnings;

use DevIo;
use Time::HiRes;
use JSON;
use JSON::XS;
use Data::Dumper;
use SetExtensions;

$Data::Dumper::Indent   = 1;
$Data::Dumper::Sortkeys = 1;

sub EspLedController_Initialize(@) {

  my ($hash) = @_;

  $hash->{DefFn}      = 'EspLedController_Define';
  $hash->{UndefFn}    = 'EspLedController_Undef';
  $hash->{ShutdownFn} = 'EspLedController_Undef';
  $hash->{SetFn}      = 'EspLedController_Set';
  $hash->{GetFn}      = 'EspLedController_Get';
  $hash->{ReadyFn}    = 'EspLedController_Ready';
  $hash->{AttrFn}     = 'EspLedController_Attr';
  $hash->{NotifyFn}   = 'EspLedController_Notify';
  $hash->{ReadFn}     = 'EspLedController_Read';
  $hash->{AttrList}   = "defaultRamp deviceName apiPassword disable:0,1" . " $readingFnAttributes";
  require "HttpUtils.pm";
  
  return undef;
}

sub EspLedController_Connect($$) {
  my ( $hash, $reopen ) = @_;
  return DevIo_OpenDev( $hash, $reopen, "EspLedController_OnInit", "EspLedController_OnConnect" );
}

sub EspLedController_Define($$) {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );

  return "wrong syntax: define <name> LedController <ip> [<port>]" if ( @a != 3 && @a != 4 );

  EspLedController_Cleanup($hash);

  my $name = $a[0];
  $hash->{IP} = $a[2];
  $hash->{PORT} = defined( $a[3] ) ? $a[3] : 9090;

  @{ $hash->{helper}->{cmdQueue} } = ();
  $hash->{helper}->{isBusy} = 0;

  # TODO remove, fixeg loglevel 5 only for debugging
  #$attr{$hash->{NAME}}{verbose} = 5;
  $hash->{helper}->{oldVal} = 100;
  $hash->{helper}->{lastCall} = undef;
  $hash->{DeviceName} = "$hash->{IP}:$hash->{PORT}";

  $attr{$name}{webCmd} = 'rgb' if (!defined($attr{$name}{webCmd}));
  $attr{$name}{icon} = 'light_led_stripe_rgb' if (!defined($attr{$name}{icon}));
  
  return undef if IsDisabled($hash);
  
  EspLedController_GetInfo($hash);
  EspLedController_GetConfig($hash);

  return EspLedController_Connect( $hash, 0 );
}

sub EspLedController_Undef($$) {
  my ( $hash, $name) = @_;

  EspLedController_Cleanup($hash);
  return undef;
}

sub EspLedController_OnInit(@) {
  my ($hash) = @_;
  $hash->{LAST_RECV} = time();
  
  my $deviceName = AttrVal( $hash->{NAME}, "deviceName", $hash->{NAME} );
  EspLedController_Set( $hash, $hash->{NAME}, "config", "config-general-device_name", $deviceName );
  EspLedController_GetConfig($hash);
  EspLedController_GetInfo($hash);
  EspLedController_GetCurrentColor($hash);
  EspLedController_QueueIntervalUpdate($hash);
  return undef;
}

sub EspLedController_OnConnect($$) {
  my ( $hash, $err ) = @_;

  if ($err) {
    Log3 $hash, 4, "$hash->{NAME}: unable to connect to LedController: $err";
  }
}

sub EspLedController_RemoveTimerCheck($) {
  my ( $hash ) = @_;
  RemoveInternalTimer( $hash, "EspLedController_Check" );
}

sub EspLedController_QueueIntervalUpdate($;$) {
  my ( $hash, $time ) = @_;

  # remove old timer (we might just want to reset it)
  EspLedController_RemoveTimerCheck($hash);
  
  # check every 10 seconds
  InternalTimer( time() + 10, "EspLedController_Check", $hash );
}

sub EspLedController_Check($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return if ( !EspLedController_CheckConnection($hash) );

  # device alive, keep bugging it
  EspLedController_QueueIntervalUpdate($hash);
}

sub EspLedController_CheckConnection($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if ( $hash->{STATE} eq "disconnected" ) {

    # we are already disconnected
    return 0;
  }

  my $lastRecvDiff = ( time() - $hash->{LAST_RECV} );

  # the controller should send keep alive every 60 seconds
  if ( $lastRecvDiff > 80 ) {
    Log3 $name, 3, "$hash->{NAME}: EspLedController_CheckConnection: Connection lost! Last data received $lastRecvDiff s ago";
    DevIo_Disconnected($hash);
    return 0;
  }
  Log3 $name, 4, "$hash->{NAME}: EspLedController_CheckConnection: Connection still alive. Last data received $lastRecvDiff s ago";

  return 1;
}

sub EspLedController_Ready($) {
  my ($hash) = @_;

  #Log3 $hash->{NAME}, 3, "EspLedController_Ready";

  return undef if IsDisabled( $hash->{NAME} );

  return EspLedController_Connect( $hash, 1 ) if ( $hash->{STATE} eq "disconnected" );
  return undef;
}

sub EspLedController_Read($) {
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my $now    = time();

  my $data = DevIo_SimpleRead($hash);
  return if ( not defined($data) );

  my $buffer = '';
  Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead" );

  #include previous partial message
  if ( defined( $hash->{PARTIAL} ) && $hash->{PARTIAL} ) {
    Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: PARTIAL: " . $hash->{PARTIAL} );
    $buffer = $hash->{PARTIAL};
  }
  else {
    Log3( $name, 5, "$hash->{NAME}: No PARTIAL buffer" );
  }

  Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: Incoming data: " . $data );

  my $tail = $buffer . $data;
  Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: Current processing buffer (PARTIAL + incoming data): " . $tail );

  #processes all complete messages
  while (1) {
    my $msg;
    ( $msg, $tail ) = EspLedController_ParseMsg( $hash, $tail );
    last if !$msg;
    
    Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: Decoding JSON message. Length: " . length($msg) . " Content: " . $msg );
    my $obj;
    eval { $obj = JSON->new->utf8(0)->decode($msg); };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: EspLedController_Read: Error parsing msg: $msg" );
      next;
    }
    
    if ( $obj->{method} eq "color_event" ) {
      my $colorMode = "raw";
      if ( exists $obj->{params}->{hsv} ) {
        $colorMode = "hsv";
        EspLedController_UpdateReadingsHsv( $hash, $obj->{params}{hsv}{h}, $obj->{params}{hsv}{s}, $obj->{params}{hsv}{v}, $obj->{params}{hsv}{ct} );
      }
      EspLedController_UpdateReadingsRaw( $hash, $obj->{params}{raw}{r}, $obj->{params}{raw}{g}, $obj->{params}{raw}{b}, $obj->{params}{raw}{cw}, $obj->{params}{raw}{ww} );
      readingsSingleUpdate( $hash, 'colorMode', $colorMode, 1 );
    }
    elsif ( $obj->{method} eq "transition_finished" ) {
      my $msg = $obj->{params}{name} . "," . ($obj->{params}{requeued} ? "requeued" : "finished");
      readingsSingleUpdate( $hash, "tranisitionFinished", $msg, 1 );
    }
    elsif ( $obj->{method} eq "keep_alive" ) {
      Log3( $hash, 4, "$hash->{NAME}: EspLedController_Read: keep_alive received" );
      $hash->{LAST_RECV} = $now;
    }
    elsif ( $obj->{method} eq "clock_slave_status" ) {
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, 'clockSlaveOffset',     $obj->{params}{offset} );
      readingsBulkUpdate( $hash, 'clockCurrentInterval', $obj->{params}{current_interval} );
      readingsEndUpdate( $hash, 1 );
    }
    else {
      Log3( $name, 3, "$hash->{NAME}: EspLedController_ProcessRead: Unknown message type: " . $obj->{method} );
    }
  }
  $hash->{PARTIAL} = $tail;
  
  Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: Tail: " . $tail );
  Log3( $name, 5, "$hash->{NAME}: EspLedController_ProcessRead: PARTIAL: " . $hash->{PARTIAL} );
  return;
}

#Parses a given string and returns ($msg,$tail). If the string contains a complete message
#(equal number of curly brackets) the return value $msg will contain this message. The
#remaining string is returned in form of the $tail variable.
sub EspLedController_ParseMsg($$) {
  my ( $hash, $buffer ) = @_;
  my $name  = $hash->{NAME};
  my $open  = 0;
  my $close = 0;
  my $msg   = '';
  my $tail  = '';
  if ($buffer) {
    foreach my $c ( split //, $buffer ) {
      if ( $open == $close && $open > 0 ) {
        $tail .= $c;
      }
      elsif ( ( $open == $close ) && ( $c ne '{' ) ) {
        Log3( $name, 3, "$hash->{NAME}: EspLedController_ParseMsg: Garbage character before message: " . $c );
      }
      else {
        if ( $c eq '{' ) {
          $open++;
        }
        elsif ( $c eq '}' ) {
          $close++;
        }
        $msg .= $c;
      }
    }
    if ( $open != $close ) {
      $tail = $msg;
      $msg  = '';
    }
  }
  return ( $msg, $tail );
}

sub EspLedController_Get(@) {
  my ( $hash, $name, $cmd, @args ) = @_;

  return undef if IsDisabled($hash);

  my $cnt = @args;

  if ( $cmd eq 'config' ) {
    EspLedController_GetConfig($hash);
  }
  elsif ( $cmd eq 'info' ) {
    EspLedController_GetInfo($hash);
  }
  elsif ( $cmd eq 'update' ) {
    EspLedController_GetCurrentColor($hash);
  }
  else {
    return "Unknown argument $cmd, choose one of config update info";
  }

  return undef;
}

sub EspLedController_ColorRangeCheck(@) {
  my ( $hash, $colorTemp ) = @_;
  my $ww = ReadingsVal( $hash->{NAME}, "config-color-colortemp-ww", -1 );
  my $cw = ReadingsVal( $hash->{NAME}, "config-color-colortemp-cw", -1 );
  
  my $result = undef;
  if ( $cw eq -1 || $ww eq -1 ) {
    $result = "No color temperature limits found. Controller config incomplete. Please issue a get config";
  }
  
  if( !EspLedController_rangeCheck( $colorTemp, $ww, $cw, 0) ){
    $result = "Color temperatur $colorTemp is out of range! Supported range is $ww to $cw";
  }
  
  # Log3 ($hash, 3, $result) if $result != undef;
  return $result;
}

sub EspLedController_Set(@);
sub EspLedController_Set(@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  
  return undef if IsDisabled($hash);
  
  Log3( $hash, 5, "$hash->{NAME} (Set) called with $cmd, busy flag is $hash->{helper}->{isBusy}\n name is $name, args " . Dumper(@args) );

  my ( $argsError, $fadeTime, $fadeSpeed, $doQueue, $direction, $doRequeue, $fadeName, $transitionType, $channels, $colorTemp );
  if ( $cmd ne "?" ) {
    my %argCmds = ( 'on' => 0, 'off' => 0, 'toggle' => 0, 'blink' => 0, 'pause' => 0, 'skip' => 0, 'continue' => 0, 'stop' => 0 );
    my $argsOffset = 1;
    $argsOffset = $argCmds{$cmd} if ( exists $argCmds{$cmd} );
    ( $argsError, $fadeTime, $fadeSpeed, $doQueue, $direction, $doRequeue, $fadeName, $transitionType, $channels ) =
      EspLedController_ArgsHelper( $hash, $argsOffset, @args );
    if ( !defined($fadeTime) && !defined($fadeSpeed) && ( $cmd ne 'blink' ) ) {
      $fadeTime = AttrVal( $hash->{NAME}, 'defaultRamp', 700 );
    }
    if ( defined($fadeSpeed) && ( $cmd eq 'blink' ) ) {
      $argsError = "Fade speed parameter cannot be used with command $cmd";
    }
  }

  return $argsError if defined($argsError);

  if ( $cmd eq 'hsv' ) {

    # expected args: <hue:0-360>,<sat:0-100>,<val:0-100>
    # HSV color values --> $hue, $sat and $val are split from arg1
    my ( $hue, $sat, $val ) = split ',', $args[0];

    $hue = undef if ( length($hue) == 0 );
    $sat = undef if ( length($sat) == 0 );
    $val = undef if ( length($val) == 0 );

    if ( !defined($hue) && !defined($sat) && !defined($val) ) {
      my $msg = "$hash->{NAME} at least one of HUE, SAT or VAL must be set";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if (defined $hue && !EspLedController_rangeCheck( $hue, 0, 360 ) ) {
      my $msg = "$hash->{NAME} HUE must be a number from 0-360 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if (defined $sat && !EspLedController_rangeCheck( $sat, 0, 100 ) ) {
      my $msg = "$hash->{NAME} SAT must be a number from 0-100 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if (defined $val && !EspLedController_rangeCheck( $val, 0, 100 ) ) {
      my $msg = "$hash->{NAME} VAL must be a number from 0-100 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }

    EspLedController_SetHSVColor( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'rgb' ) {

    # the native mode of operation for those controllers is HSV
    # I am converting RGB into HSV and then set that
    # This is to make use of the internal color compensation of the controller

    # sanity check, is string in required format?
    if ( !defined( $args[0] ) || $args[0] !~ /^[0-9A-Fa-f]{6}$/ ) {
      Log3( $hash, 3, "$hash->{NAME} RGB requires parameter: Hex RRGGBB (e.g. 3478DE)" );
      return "$hash->{NAME} RGB requires parameter: Hex RRGGBB (e.g. 3478DE)";
    }

    # break down param string into discreet RGB values, also Hex to Int
    my $red   = hex( substr( $args[0], 0, 2 ) );
    my $green = hex( substr( $args[0], 2, 2 ) );
    my $blue  = hex( substr( $args[0], 4, 2 ) );
    Log3( $hash, 5, "$hash->{NAME} raw: $args[0], r: $red, g: $green, b: $blue" );
    my ( $hue, $sat, $val ) = EspLedController_RGB2HSV( $hash, $red, $green, $blue );
    EspLedController_SetHSVColor( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'ct' ) {
    my $colorTemp = $args[0];
    my $res = EspLedController_ColorRangeCheck( $hash, $colorTemp );
    return $res if ($res);

    EspLedController_SetHSVColor( $hash, undef, undef, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'white' ) {
    my $colorTemp = undef;
    
    if ( @args > 0 ) {
        $colorTemp = $args[0];
        my $res = EspLedController_ColorRangeCheck( $hash, $colorTemp );
        return $res if ($res);
    }

    EspLedController_SetHSVColor( $hash, undef, 0, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'on' ) {

    # Add check to only do something if the controller is REALLY turned off, i.e. val eq 0
    my $state = ReadingsVal( $hash->{NAME}, "stateLight", "off" );
    return undef if ( $state eq "on" );

    # OK, state was off
    # val initialized from internal value.
    # if internal was 0, default to 100;
    my $val = $hash->{helper}->{oldVal};
    if ( $val eq 0 ) {
      $val = 100;
    }

    EspLedController_SetHSVColor( $hash, undef, undef, $val, undef, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'off' ) {

    # Store old val in internal for use by on command.
    $hash->{helper}->{oldVal} = ReadingsVal( $hash->{NAME}, "val", 0 );

    # Now set val to zero, read other values and "turn out the light"...
    EspLedController_SetHSVColor( $hash, "+0", "+0", 0, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'toggle' ) {
    my $state = ReadingsVal( $hash->{NAME}, "stateLight", "off" );
    if ( $state eq "on" ) {
      return EspLedController_Set( $hash, $name, "off", @args );
    }
    else {
      return EspLedController_Set( $hash, $name, "on", @args );
    }
  }
  elsif ( $cmd eq 'toggle_fw' ) {
    # still experimental toggle using new toggle function in firmware. This might replace the regular toggle at some point
    my $param = EspLedController_GetHttpParams( $hash, "POST", "toggle", "" );
    $param->{parser} = \&EspLedController_ParseBoolResult;

    EspLedController_addCall( $hash, $param );
  }
  elsif ( $cmd eq "dimup" || $cmd eq "up" ) {

    # dimming value is first parameter, add to $val and keep hue and sat the way they were.
    my $dim = $args[0];
    EspLedController_SetHSVColor( $hash, undef, undef, "+" . $dim, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue,
      $fadeName );
  }
  elsif ( $cmd eq "dimdown" || $cmd eq "down" ) {

    # dimming value is first parameter, add to $val and keep hue and sat the way they were.
    my $dim = $args[0];
    EspLedController_SetHSVColor( $hash, undef, undef, "-" . $dim, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue,
      $fadeName );
  }
  elsif ( $cmd eq 'val' || $cmd eq 'dim' || $cmd eq 'pct' ) {

    # Set val from arguments, keep hue and sat the way they were
    my $val = $args[0];

    # input validation
    if ( !EspLedController_rangeCheck( $val, 0, 100 ) ) {
      my $msg = "$hash->{NAME} value must be a number from 0-100 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }

    Log3( $hash, 5, "$hash->{NAME} setting VAL to $val" );
    EspLedController_SetHSVColor( $hash, undef, undef, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'sat' ) {

    # get new saturation value $sat from args, keep hue and val the way they were.
    my $sat = $args[0];

    # input validation
    if ( !EspLedController_rangeCheck( $sat, 0, 100 ) ) {
      my $msg = "$hash->{NAME} sat value must be a number from 0-100 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }

    Log3( $hash, 5, "$hash->{NAME} setting SAT to $sat" );
    EspLedController_SetHSVColor( $hash, undef, $sat, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'hue' ) {

    # get new hue value $sat from args, keep sat and val the way they were.
    my $hue = $args[0];

    # input validation
    if ( !EspLedController_rangeCheck( $hue, 0, 360 ) ) {
      my $msg = "$hash->{NAME} hue value must be a number from 0-360 or a relative value (+/-)";
      Log3( $hash, 3, $msg );
      return $msg;
    }

    Log3( $hash, 5, "$hash->{NAME} setting HUE to $hue" );

    EspLedController_SetHSVColor( $hash, $hue, undef, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'raw' ) {
    my ( $red, $green, $blue, $ww, $cw ) = split ',', $args[0];

    EspLedController_SetRAWColor( $hash, $red, $green, $blue, $ww, $cw, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'continue' || $cmd eq 'pause' || $cmd eq 'skip' || $cmd eq 'stop' ) {
    EspLedController_SetChannelCommand( $hash, $cmd, $channels );
  }
  elsif ( $cmd eq 'blink' ) {
    my $param = EspLedController_GetHttpParams( $hash, "POST", "blink", "" );
    $param->{parser} = \&EspLedController_ParseBoolResult;

    my $body = {};

    if ( defined $channels ) {
      my @c = split /,/, $channels;
      $body->{channels} = \@c;
    }
    $body->{t} = $fadeTime  if defined $fadeTime;
    $body->{q} = $doQueue   if defined($doQueue);
    $body->{r} = $doRequeue if defined($doRequeue);

    eval { $param->{data} = EspLedController_EncodeJson( $hash, $body ) };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error encoding blink request $@" );
      return undef;
    }
    EspLedController_addCall( $hash, $param );
  }
  elsif ( $cmd eq 'config' ) {
    return "Invalid syntax: Use 'set <device> config <parameter> <value>'" if ( @args != 2 );

    my %config = ( $args[0] => $args[1] );
    if ( !EspLedController_SendConfig($hash, \%config) ) {
      return "Error sending config!";
    }
    
    EspLedController_GetConfig($hash);
  }
  elsif ( $cmd eq 'restart' ) {
    EspLedController_SendSystemCommand( $hash, $cmd );
  }
  elsif ( $cmd eq 'fw_update' ) {
    return "Invalid syntax: Use 'set <device> fw_update [<URL to version.json>] [<force>]'" if ( @args > 2 );

    my $force = 0;
    my $url = ReadingsVal( $hash->{NAME}, "config-ota-url", "" );
    if ( defined( $args[0] ) ) {
      if ( EspLedController_isNumeric( $args[0] ) ) {
        $force = $args[0];
      }
      else {
        $url = $args[0];
        $force = defined( $args[1] ) ? $args[1] : 0;
      }
    }

    EspLedController_FwUpdate_GetVersion( $hash, $url, $force );
  }
  elsif ( $cmd eq 'rotate' ) {

    my $rot = $args[0];
    Log3( $hash, 2, "$hash->{NAME}: Command 'rotate' is deprecated! Please use 'hue' or 'hsv' wit relative values (+/-xxx)!" );
    EspLedController_SetHSVColor( $hash, "+$rot", undef, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'security' ) {
    return "Invalid syntax: Use 'set <device> security <0|1> [<password>]'" if ( @args == 0 );
    my $enable = $args[0];
    
    if ( $enable ) {
      return "Invalid syntax: Use 'set <device> security 1 <password>'" if ( @args != 2 );
      
      my %config = ( 'config-security-api_secured' => 1, 'config-security-api_password' => $args[1] );
      if ( !EspLedController_SendConfig($hash, \%config) ) {
        return "Error sending config!";
      }
    }
    else {
      return "Invalid syntax: Use 'set <device> security 0'" if ( @args != 1 );

      my %config = ( 'config-security-api_secured' => 0 );
      if ( !EspLedController_SendConfig($hash, \%config) ) {
        return "Error sending config!";
      }
    }
    
    EspLedController_GetConfig($hash);
  }
  else {
    my $cmdList = "hsv:colorpicker,HSV,hue,0,1,360,sat,0,1,100,val,0,1,100 rgb:colorpicker,RGB state hue:slider,0,0.1,360 sat:slider,0,1,100 white stop val:slider,0,1,100 pct:slider,0,1,100 dim:slider,0,1,100 dimup:slider,0,1,100 dimdown:slider,0,1,100 on off toggle toggle_fw raw pause continue blink skip config restart fw_update ct:colorpicker,CT,2700,10,6000 rotate security";
    return SetExtensions( $hash, $cmdList, $name, $cmd, @args );
  }

  return undef;
}

sub EspLedController_SendConfig($$) {
  my ( $hash, $config ) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "POST", "config", "" );
  $param->{parser} = \&EspLedController_ParseBoolResult;

  # prepare request body
  my $body = {};

  foreach my $key (keys %$config) {
    my $curNode = $body;
    
    my @toks = split /-/, $key;
    return "Invalid config parameter name!" if ( @toks < 2 );

    for my $i ( 1 .. ($#toks) ) {
      if ( $i == ($#toks) ) {
        $curNode->{ $toks[$i] } = $config->{$key};
      }
      else {
        if ( exists $curNode->{ $toks[$i] } ) {
          $curNode = $curNode->{ $toks[$i] };
        }
        else {
          my $newNode = {};
          $curNode->{ $toks[$i] } = $newNode;
          $curNode = $newNode;
        }
      }
    }
  }
  
  eval { $param->{data} = EspLedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding config request $@" );
    return 0;
  }
    
  EspLedController_addCall( $hash, $param );
  
  return 1;
}

sub EspLedController_SendSystemCommand(@) {
  my ( $hash, $cmd ) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "POST", "system", "" );
  $param->{parser} = \&EspLedController_ParseBoolResult;

  my $body = { cmd => $cmd };
  eval { $param->{data} = EspLedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding system command request $@" );
    return undef;
  }
  EspLedController_addCall( $hash, $param );
}

sub EspLedController_Cleanup(@) {
  my ($hash) = @_;
  EspLedController_RemoveTimerCheck($hash);
  DevIo_CloseDev($hash);
}

sub EspLedController_GetConfig(@) {
  my ($hash) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "GET", "config", "" );
  $param->{parser} = \&EspLedController_ParseConfig;

  EspLedController_addCall( $hash, $param );
}

sub EspLedController_SetChannelCommand(@) {
  my ( $hash, $cmd, $channels ) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "POST", $cmd, "" );
  $param->{parser} = \&EspLedController_ParseBoolResult;

  my $body = {};
  if ( defined $channels ) {
    my @c = split /,/, $channels;
    $body->{channels} = \@c;
  }

  eval { $param->{data} = EspLedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding channel command request $@" );
    return undef;
  }
  EspLedController_addCall( $hash, $param );
}

sub EspLedController_Attr(@) {

  my ( $cmd, $device, $attribName, $attribVal ) = @_;
  my $hash = $defs{$device};
  
  if ( $attribName eq "disable" ) {
    if($cmd eq "set" && ($attribVal || !defined($attribVal))) {
      DevIo_CloseDev($hash);
      $hash->{STATE} = "Disabled";
    } else {
      if (IsDisabled($hash)) {
        $hash->{STATE} = "Initialized";
           
        EspLedController_Connect( $hash, 0 );
      }
    }
  }

  Log3( $hash, 4, "$hash->{NAME} attrib $attribName $cmd" );
  return undef;
}

# restore previous settings (as set statefile)
sub EspLedController_Notify(@) {

  my ( $hash, $eventSrc ) = @_;
  my $events = deviceEvents( $eventSrc, 1 );
  my ( $hue, $sat, $val );
}

sub EspLedController_GetInfo(@) {
  my ($hash) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "GET", "info", "" );
  $param->{parser} = \&EspLedController_ParseInfo;

  EspLedController_addCall( $hash, $param );
  return undef;
}

sub EspLedController_IterateConfigHash($$$);

sub EspLedController_IterateConfigHash($$$) {
  my ( $hash, $readingPrefix, $ref ) = @_;
  foreach my $key ( keys %{$ref} ) {
    my $newPrefix = $readingPrefix . "-" . $key;
    if ( ref( $ref->{$key} ) eq "HASH" ) {
      EspLedController_IterateConfigHash( $hash, $newPrefix, $ref->{$key} );
    }
    else {
      readingsBulkUpdate( $hash, $newPrefix, $ref->{$key} );
    }
  }
}

sub EspLedController_ParseConfig(@) {
  my ( $hash, $err, $data ) = @_;

  Log3( $hash, 4, "$hash->{NAME}: got config response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving config" );
  }
  elsif ($data) {
    Log3( $hash, 4, "$hash->{NAME}: config response data $data" );
    my $jsonDecode;
    eval {

      # TODO: Can't we just store the instance of the JSON parser somewhere?
      # Would that improve performance???
      eval { $jsonDecode = JSON->new->utf8(1)->decode($data); };
    };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error decoding config response $@" );
    }
    else {
      fhem( "deletereading " . $hash->{NAME} . " config-.*", 1 );
      readingsBeginUpdate($hash);
      EspLedController_IterateConfigHash( $hash, "config", $jsonDecode );
      readingsEndUpdate( $hash, 1 );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retrieving config" );
  }
  return undef;
}

sub EspLedController_ParseInfo(@) {
  my ( $hash, $err, $data ) = @_;

  my $res;

  Log3( $hash, 3, "$hash->{NAME}: got info response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving info" );
  }
  elsif ($data) {
    Log3( $hash, 3, "$hash->{NAME}: info response data $data" );
    eval {

      # TODO: Can't we just store the instance of the JSON parser somewhere?
      # Would that improve performance???
      eval { $res = JSON->new->utf8(1)->decode($data); };
    };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error decoding info response $@" );
    }
    else {
      fhem( "deletereading " . $hash->{NAME} . " info-.*", 1 );
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, 'info-deviceid',               $res->{deviceid} );
      readingsBulkUpdate( $hash, 'info-firmware',               $res->{git_version} );
      readingsBulkUpdate( $hash, 'info-sming_version',          $res->{sming} );
      readingsBulkUpdate( $hash, 'info-webapp_version',         $res->{webapp_version} );
      readingsBulkUpdate( $hash, 'info-heap_free',              $res->{heap_free} );

      readingsBulkUpdate( $hash, 'info-event_num_clients',      $res->{event_num_clients} );
      readingsBulkUpdate( $hash, 'info-current_rom_slot',       $res->{current_rom} );
      readingsBulkUpdate( $hash, 'info-uptime',                 $res->{uptime} );

      readingsBulkUpdate( $hash, 'info-connection-ssid',        $res->{connection}->{ssid} );
      readingsBulkUpdate( $hash, 'info-connection-dhcp',        $res->{connection}->{dhcp} );
      readingsBulkUpdate( $hash, 'info-connection-ip_address',  $res->{connection}->{ip} );
      readingsBulkUpdate( $hash, 'info-connection-netmask',     $res->{connection}->{netmask} );
      readingsBulkUpdate( $hash, 'info-connection-gateway',     $res->{connection}->{gateway} );
      readingsBulkUpdate( $hash, 'info-connection-mac',         $res->{connection}->{mac} );
      
      readingsEndUpdate( $hash, 1 );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retrieving info" );
  }
  return undef;
}

sub EspLedController_FwUpdate_GetVersion(@) {
  my ( $hash, $url, $force ) = @_;

  $hash->{helper}->{fwUpdateForce} = $force;
  $hash->{helper}->{fw_update_starttime} = time(); # store when fw_update is started (-> now)

  my $params = {
    url      => $url,
    timeout  => 30,
    hash     => $hash,
    method   => "GET",
    header   => "User-Agent: fhem\r\nAccept: application/json\r\nContent-Type: application/json",
    callback => \&EspLedController_ParseFwVersionResult,
    forceFw  => $force
  };

  HttpUtils_NonblockingGet($params);
}

sub EspLedController_QueueFwUpdateProgressCheck(@) {
  my ($hash) = @_;

  # give up polling for fw update progress after 5 minutes
  my $maxFwUpdateDuration = 300;
  if (time() - $hash->{helper}->{fw_update_starttime} > $maxFwUpdateDuration) {
    my $msg = "Update cancelled. Did not finish within $maxFwUpdateDuration seconds";
    Log3( $hash, 3, "$hash->{NAME}: Firmware update failed: $msg" );
    readingsSingleUpdate( $hash, "lastFwUpdate", "Error: $msg", 1 );
    return undef;
  }  
  
  InternalTimer( time() + 1, "EspLedController_FwUpdateProgressCheck", $hash, 0 );
}

sub EspLedController_FwUpdateProgressCheck(@) {
  my ($hash) = @_;
  my $param = EspLedController_GetHttpParams( $hash, "GET", "update", "" );
  $param->{parser} = \&EspLedController_ParseFwUpdateProgress;

  EspLedController_addCall( $hash, $param );
}

sub EspLedController_ParseFwVersionResult(@) {
  my ( $param, $err, $data ) = @_;
  my $hash  = $param->{hash};
  my $force = $param->{forceFw};

  my $res;

  Log3( $hash, 4, "$hash->{NAME}: EspLedController_FwVersionCallback" );
  if ($err) {
    readingsSingleUpdate( $hash, "lastFwUpdate", "Error: $err", 1 );
    Log3( $hash, 2, "$hash->{NAME}: EspLedController_FwVersionCallback error: $err" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      readingsSingleUpdate( $hash, "lastFwUpdate", "error decoding FW version", 1 );
      Log3( $hash, 2, "$hash->{NAME}: EspLedController_ParseFwVersionResult error decoding FW version: $@" );
      return undef;
    }

    my $curFw = ReadingsVal( $hash->{NAME}, "info-firmware", "" );
    my $newFw = $res->{rom}{fw_version};
    if ( $newFw eq $curFw ) {
      if ($force) {
        Log3( $hash, 3, "$hash->{NAME}: Firmware already installed: $newFw. Still updating due to force flag!" );
      }
      else {
        my $msg = "Update skipped. Firmware already installed: $newFw";
        readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
        Log3( $hash, 3, "$hash->{NAME}: $msg" );
        return undef;
      }
    }

    my $msg = "Updating firmware now. Current firmware: $curFw New firmare: $newFw";
    readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
    Log3( $hash, 3, "$hash->{NAME}: $msg" );

    my $param = EspLedController_GetHttpParams( $hash, "POST", "update", "" );
    $param->{parser} = \&EspLedController_ParseBoolResult;

    $param->{data} = $data;
    EspLedController_addCall( $hash, $param );

    # queue next query or give up after fw_update is running for more than 300 seconds without result
    EspLedController_QueueFwUpdateProgressCheck($hash);
  }

  return undef;
}

sub EspLedController_ParseFwUpdateProgress(@) {
  my ( $hash, $err, $data ) = @_;

  my $res;
  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: EspLedController_ParseFwUpdateProgress error: $err" );
    readingsSingleUpdate( $hash, "lastFwUpdate", "ParseFwUpdateProgress error: $err", 1 );
    EspLedController_QueueFwUpdateProgressCheck($hash);
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      my $msg = "error decoding FW update status $@";
      readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
      Log3( $hash, 4, "$hash->{NAME}: $msg" );
      return undef;
    }

    my $status = $res->{status};
    Log3( $hash, 3, "$hash->{NAME}: EspLedController_ParseFwUpdateProgress. status: $status" );

    if ( $status == 0 ) {
      # NOT UPDATING
      readingsSingleUpdate( $hash, "lastFwUpdate", "Not updating", 1 );
    }
    elsif ( $status == 1 ) {
      # OTA_PROCESSING
      EspLedController_QueueFwUpdateProgressCheck($hash);
      readingsSingleUpdate( $hash, "lastFwUpdate", "Update in progress", 1 );
    }
    elsif ( $status == 2 ) {
      my $msg = "Update successful - Restarting device...";
      readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
      Log3( $hash, 3, "$hash->{NAME}: EspLedController_ParseFwUpdateProgress - $msg" );
      EspLedController_SendSystemCommand( $hash, "restart" );
    }
    elsif ( $status == 4 ) {

      # OTA_FAILED
      Log3( $hash, 3, "$hash->{NAME}: EspLedController_ParseFwUpdateProgress - Update failed!" );
      readingsSingleUpdate( $hash, "lastFwUpdate", "Update failed!", 1 );
    }
    else {
      Log3( $hash, 3, "$hash->{NAME}: EspLedController_ParseFwUpdateProgress - Unexpected update status: $status" );
      readingsSingleUpdate( $hash, "lastFwUpdate", "Unexpected update status: $status", 1 );
    }
  }

  return undef;
}

sub EspLedController_GetHttpParams(@) {
  my ( $hash, $method, $path, $query ) = @_;
  my $ip = $hash->{IP};

  my $param = {
    url      => "http://$ip/$path?$query",
    timeout  => 30,
    hash     => $hash,
    method   => $method,
    header   => "User-Agent: fhem\r\nAccept: application/json\r\nContent-Type: application/json",
    callback => \&EspLedController_callback
  };
  return $param;
}

sub EspLedController_GetCurrentColor(@) {
  my ($hash) = @_;
  my $ip = $hash->{IP};

  my $param = EspLedController_GetHttpParams( $hash, "GET", "color", "" );
  $param->{parser} = \&EspLedController_ParseColor;

  EspLedController_addCall( $hash, $param );
  return undef;
}

sub EspLedController_ParseColor(@) {
  my ( $hash, $err, $data ) = @_;
  my $res;

  Log3( $hash, 4, "$hash->{NAME}: got color response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving color" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      Log3( $hash, 4, "$hash->{NAME}: error decoding color response $@" );
    }
    else {
      EspLedController_UpdateReadingsHsv( $hash, $res->{hsv}->{h}, $res->{hsv}->{s}, $res->{hsv}->{v}, $res->{hsv}->{ct} );
      EspLedController_UpdateReadingsRaw( $hash, $res->{raw}->{r}, $res->{raw}->{g}, $res->{raw}->{b}, $res->{raw}->{cw}, $res->{raw}->{ww} );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retriving HSV color" );
  }
  return undef;
}

sub EspLedController_fixHueCircular(@) {
  my ($hue) = @_;

  $hue = $hue % 360 if ( $hue > 360 );
  while ( $hue < 0 ) {
    $hue = 360 + $hue;
  }
  return $hue;
}

sub EspLedController_GetQueuePolicyFlags($) {
  my ($q) = @_;
  return "q" if ( $q eq "back" );
  return "f" if ( $q eq "front" );
  return "e" if ( $q eq "front_reset" );
  return undef;
}

sub EspLedController_SetHSVColor_Slaves(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $name ) = @_;

  my $slaveAttr = AttrVal( $hash->{NAME}, "slaves", "" );
  return if ( $slaveAttr eq "" );

  my $flags = '';
  $flags .= EspLedController_GetQueuePolicyFlags($doQueue);
  $flags .= "r" if defined($doRequeue) && $doRequeue;
  $flags .= ":$name" if defined($name);

  $fadeTime /= 1000.0;

  my @slaves = split / /, $slaveAttr;
  for my $slaveDev (@slaves) {
    my ( $slaveName, $offsets ) = split /:/, $slaveDev;

    if ( defined $offsets ) {
      my @offSplit = split /,/, $offsets;
      $hue += $offSplit[0];
      $sat += $offSplit[1];
      $val += $offSplit[2];

      $val = 0   if $val < 0;
      $val = 100 if $val > 100;
      $sat = 0   if $sat < 0;
      $sat = 100 if $sat > 100;
      $hue = EspLedController_fixHueCircular($hue);
    }

    my $slaveCmd = "set $slaveName hsv $hue,$sat,$val $fadeTime $flags";
    Log3( $hash, 3, "$hash->{NAME}: Issueing slave command: $slaveCmd" );
    fhem($slaveCmd);
  }

  return undef;
}

sub EspLedController_EncodeJson($$) {
  my ( $hash, $obj ) = @_;
  my $data;
  eval { $data = JSON->new->utf8(1)->encode($obj); };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding HSV color request $@" );
    return undef;
  }
  return $data;
}

sub EspLedController_SetHSVColor(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $name ) = @_;
  Log3( $hash, 5, "$hash->{NAME}: called SetHSVColor");# $hue, $sat, $val, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doRequeue, $name)" );

  if ( !defined($hue) && !defined($sat) && !defined($val) && !defined($colorTemp) ) {
    Log3( $hash, 3, "$hash->{NAME}: error: All HSVCT components undefined!" );
    return undef;
  }

  if ( defined($fadeTime) && defined($fadeSpeed) ) {
    Log3( $hash, 3, "$hash->{NAME}: error: fadeTime and fadeSpeed cannot be used at the same time!" );
    return undef;
  }

  my $ip = $hash->{IP};

  my $cmd;
  $cmd->{hsv}->{h}  = $hue            if defined($hue);
  $cmd->{hsv}->{s}  = $sat            if defined($sat);
  $cmd->{hsv}->{v}  = $val            if defined($val);
  $cmd->{hsv}->{ct} = $colorTemp      if defined($colorTemp);
  $cmd->{cmd}       = $transitionType if defined($transitionType);
  $cmd->{t}         = $fadeTime       if defined($fadeTime);
  $cmd->{s}         = $fadeSpeed      if defined($fadeSpeed);
  $cmd->{q}         = $doQueue        if defined($doQueue);
  $cmd->{d}         = $direction      if defined($direction);
  $cmd->{r}         = $doRequeue      if defined($doRequeue);
  $cmd->{name}      = $name           if defined($name);

  my $data;
  eval { $data = JSON->new->utf8(1)->encode($cmd); };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding HSV color request $@" );
  }
  else {

    Log3( $hash, 5, "$hash->{NAME}: encoded json data: $data " );

    my $param = {
      url      => "http://$ip/color",
      data     => $data,
      cmd      => $cmd,
      timeout  => 30,
      hash     => $hash,
      method   => "POST",
      header   => "User-Agent: fhem\r\nAccept: application/json\r\nContent-Type: application/json",
      parser   => \&EspLedController_ParseBoolResult,
      callback => \&EspLedController_callback,
      loglevel => 5
    };

    Log3( $hash, 5, "$hash->{NAME}: set HSV color request: $data" );
    EspLedController_addCall( $hash, $param );
  }

  EspLedController_SetHSVColor_Slaves(@_);

  return undef;
}

sub EspLedController_UpdateReadingsHsv(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp ) = @_;
  
  my $h = defined $hue ? $hue : "-";
  my $s = defined $sat ? $sat : "-";
  my $v = defined $val ? $val : "-";
  my $ct = defined $colorTemp ? $colorTemp : "-";
  
  my $xrgb = "-";
  if (defined $hue && defined $sat && defined $val) {
    my ( $red, $green, $blue ) = EspLedController_HSV2RGB( $hue, $sat, $val );
    $xrgb = sprintf( "%02x%02x%02x", $red, $green, $blue );
  }
    
  my $hsv = "$h,$s,$v";
  
  readingsBeginUpdate($hash);
  readingsBulkUpdate( $hash, 'hue', $h );
  readingsBulkUpdate( $hash, 'sat', $s );
  readingsBulkUpdate( $hash, 'val', $v );
  readingsBulkUpdate( $hash, 'pct', $v );
  readingsBulkUpdate( $hash, 'ct',  $ct );
  readingsBulkUpdate( $hash, 'hsv', $hsv );
  readingsBulkUpdate( $hash, 'rgb', $xrgb );  
  readingsEndUpdate( $hash, 1 );
  return undef;
}

sub EspLedController_UpdateReadingsRaw(@) {
  my ( $hash, $r, $g, $b, $cw, $ww ) = @_;

  readingsBeginUpdate($hash);
  readingsBulkUpdate( $hash, 'raw_red',   $r );
  readingsBulkUpdate( $hash, 'raw_green', $g );
  readingsBulkUpdate( $hash, 'raw_blue',  $b );
  readingsBulkUpdate( $hash, 'raw_cw',    $cw );
  readingsBulkUpdate( $hash, 'raw_ww',    $ww );
  readingsBulkUpdate( $hash, 'stateLight', $r + $g + $b + $cw + $ww > 0 ? 'on' : 'off' );
  readingsEndUpdate( $hash, 1 );
  return undef;
}

sub EspLedController_SetRAWColor(@) {
  my ( $hash, $red, $green, $blue, $warmWhite, $coldWhite, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doReQueue, $name ) = @_;

  my $param = EspLedController_GetHttpParams( $hash, "POST", "color", "" );
  $param->{parser} = \&EspLedController_ParseBoolResult;

  my $body = {};
  $body->{raw}->{r}  = $red            if defined($red);
  $body->{raw}->{g}  = $green          if defined($green);
  $body->{raw}->{b}  = $blue           if defined($blue);
  $body->{raw}->{ww} = $warmWhite      if defined($warmWhite);
  $body->{raw}->{cw} = $coldWhite      if defined($coldWhite);
  $body->{raw}->{ct} = $colorTemp      if defined($colorTemp);
  $body->{cmd}       = $transitionType if defined($transitionType);
  $body->{t}         = $fadeTime       if defined($fadeTime);
  $body->{q}         = $doQueue        if defined($doQueue);
  $body->{d}         = $direction      if defined($direction);
  $body->{r}         = $doReQueue      if defined($doReQueue);
  $body->{name}      = $name           if defined($name);

  eval { $param->{data} = EspLedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding RAW color request $@" );
    return undef;
  }

  EspLedController_addCall( $hash, $param );
}

sub EspLedController_ParseBoolResult(@) {
  my ( $hash, $err, $data ) = @_;
  my $res;

  Log3( $hash, 5, "$hash->{NAME}: EspLedController_ParseBoolResult" );
  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: EspLedController_ParseBoolResult error: $err" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ( exists $res->{error} ) {
      Log3( $hash, 3, "$hash->{NAME}: error EspLedController_ParseBoolResult: $data" );
    }
    elsif ( exists $res->{success} ) {
      Log3( $hash, 5, "$hash->{NAME}: EspLedController_ParseBoolResult success" );
    }
    else {
      Log3( $hash, 2, "$hash->{NAME}: EspLedController_ParseBoolResult malformed answer" );
    }
  }

  return undef;
}

###############################################################################
#
# queue and send a api call
#
###############################################################################

sub EspLedController_addCall(@) {
  my ( $hash, $param ) = @_;

  Log3( $hash, 5, "$hash->{NAME}: add to queue: " . Dumper $param->{data} );

  my $password = AttrVal( $hash->{NAME}, "apiPassword", undef );
  if (defined($password)) {
    Log3( $hash, 5, "$hash->{NAME}: Setting basic auth data");
    $param->{user} = 'admin';
    $param->{pwd} = $password;
  }
  
  # add to queue
  push @{ $hash->{helper}->{cmdQueue} }, $param;

  # return if busy
  return if $hash->{helper}->{isBusy};

  # do the call
  EspLedController_doCall($hash);

  return undef;
}

sub EspLedController_doCall(@) {
  my ($hash) = @_;

  return undef if IsDisabled($hash);

  return unless scalar @{ $hash->{helper}->{cmdQueue} };

  # set busy and do it
  $hash->{helper}->{isBusy} = 1;
  my $param = shift @{ $hash->{helper}->{cmdQueue} };

  $hash->{helper}->{lastCall} = $param;
  
  HttpUtils_NonblockingGet($param);

  return undef;
}

sub EspLedController_callback(@) {
  my ( $param, $err, $data ) = @_;
  my ($hash) = $param->{hash};
  
  return undef if IsDisabled($hash);

  if (!$err && $param->{code} != 200 && $param->{httpheader} =~ m/Retry-After: (\d)/) {
    # TODO: Retry-After with timestamp not supported
    Log3( $hash, 3, "$hash->{NAME}: Server replied with HTTP Retry-After: $1");
    InternalTimer( time() + $1, "HttpUtils_NonblockingGet", $hash->{helper}->{lastCall} );
    return undef;
  }
  
  $hash->{helper}->{isBusy} = 0;

  # do the result-parser callback
  my $parser = $param->{parser};
  &$parser( $hash, $err, $data );

  EspLedController_doCall($hash);

  return undef;
}

###############################################################################
#
# helper functions
#
###############################################################################

sub EspLedController_RGB2HSV(@) {
  my ( $hash, $red, $green, $blue ) = @_;
  $red   = ( $red * 1023 ) / 255;
  $green = ( $green * 1023 ) / 255;
  $blue  = ( $blue * 1023 ) / 255;

  Log3( $hash, 3, "$hash->{NAME}: EspLedController_RGB2HSV: $red - $green - $blue" );
  
  my ( $max, $min, $delta );
  my ( $hue, $sat, $val );

  $max = $red   if ( ( $red >= $green ) && ( $red >= $blue ) );
  $max = $green if ( ( $green >= $red ) && ( $green >= $blue ) );
  $max = $blue  if ( ( $blue >= $red )  && ( $blue >= $green ) );
  $min = $red   if ( ( $red <= $green ) && ( $red <= $blue ) );
  $min = $green if ( ( $green <= $red ) && ( $green <= $blue ) );
  $min = $blue  if ( ( $blue <= $red )  && ( $blue <= $green ) );

  $val = int( ( $max / 10.23 ) + 0.5 );
  $delta = $max - $min;

  $sat = ($max > 0.0) ? int( ( ( $delta / $max ) * 100 ) + 0.5 ) : 0;
    
  if ($delta > 0.0) {
    $hue = ( $green - $blue ) / $delta if ( $red == $max );
    $hue = 2 + ( $blue - $red ) / $delta  if ( $green == $max );
    $hue = 4 + ( $red - $green ) / $delta if ( $blue == $max );
    $hue = int( ( $hue * 60 ) + 0.5 );
  }
  else {
    $hue = 0.0;
  }
  $hue += 360 if ( $hue < 0 );
  return $hue, $sat, $val;
}

sub EspLedController_HSV2RGB(@) {
  my ( $hue, $sat, $val ) = @_;

  if ( $sat == 0 ) {
    return int( ( $val * 2.55 ) + 0.5 ), int( ( $val * 2.55 ) + 0.5 ), int( ( $val * 2.55 ) + 0.5 );
  }
  $hue %= 360;
  $hue /= 60;
  $sat /= 100;
  $val /= 100;

  my $i = int($hue);

  my $f = $hue - $i;
  my $p = $val * ( 1 - $sat );
  my $q = $val * ( 1 - $sat * $f );
  my $t = $val * ( 1 - $sat * ( 1 - $f ) );

  my ( $red, $green, $blue );

  if ( $i == 0 ) {
    ( $red, $green, $blue ) = ( $val, $t, $p );
  }
  elsif ( $i == 1 ) {
    ( $red, $green, $blue ) = ( $q, $val, $p );
  }
  elsif ( $i == 2 ) {
    ( $red, $green, $blue ) = ( $p, $val, $t );
  }
  elsif ( $i == 3 ) {
    ( $red, $green, $blue ) = ( $p, $q, $val );
  }
  elsif ( $i == 4 ) {
    ( $red, $green, $blue ) = ( $t, $p, $val );
  }
  else {
    ( $red, $green, $blue ) = ( $val, $p, $q );
  }
  return ( int( ( $red * 255 ) + 0.5 ), int( ( $green * 255 ) + 0.5 ), int( ( $blue * 255 ) + 0.5 ) );
}

sub EspLedController_ArgsHelper(@) {
  my ( $hash, $offset, @args ) = @_;

  my ( $channels, $requeue, $flags, $time, $speed, $name );
  my $queue          = 'single';
  my $d              = '1';
  my $transitionType = 'fade';
  for my $i ( $offset .. $#args ) {
    my $arg = $args[$i];
    if ( $arg =~ /\((.*)\)/ ) {

      $channels = $1;
    }
    elsif ( EspLedController_isNumeric($arg) ) {
      $time = $arg * 1000;
    }
    elsif ( substr( $arg, 0, 1 ) eq "s" && EspLedController_isNumeric( substr( $arg, 1 ) ) ) {
      $speed = substr( $arg, 1 );
    }
    else {
      ( $flags, $name ) = split /:/, $arg;
      my $queueBack       = ( $flags =~ m/q/i );
      my $queueFront      = ( $flags =~ m/f/i );
      my $queueFrontReset = ( $flags =~ m/e/i );

      if ($queueBack) {
        $queue = 'back';
      }
      elsif ($queueFront) {
        $queue = 'front';
      }
      elsif ($queueFrontReset) {
        $queue = 'front_reset';
      }

      $requeue = 'true' if ( $flags =~ m/r/i );
      $d = ( $flags =~ m/l/ ) ? 0 : 1;

      $transitionType = 'solid' if ( $flags =~ m/s/i );
    }
  }
  #Log3( $hash, 5, "$hash->{NAME}: EspLedController_ArgsHelper: Time: $time | Speed: $speed | Q: $queue | RQ: $requeue | Name: $name | trans: $transitionType | Ch: $channels" );
  return ( undef, $time, $speed, $queue, $d, $requeue, $name, $transitionType, $channels );
}

sub EspLedController_isNumeric {
  defined $_[0] && $_[0] =~ /^\d+.?\d*/;
}

sub EspLedController_isNumericRelative {
  defined $_[0] && $_[0] =~ /^[+-]\d+.?\d*/;
}

sub EspLedController_rangeCheck(@) {
  my ( $val, $min, $max, $canBeRelative ) = @_;
  
  $canBeRelative = 1 if !defined($canBeRelative);
  return 1 if EspLedController_isNumericRelative($val) and $canBeRelative;
  return EspLedController_isNumeric($val) && $val >= $min && $val <= $max;
}

1;

=begin html

<a name="LedController"></a>
<h3>LedController</h3>
 <ul>
  <p>The module controls the led controller made by patrick jahns.</p> 
  <p>Additional information you will find in the <a href="https://forum.fhem.de/index.php/topic,48918.0.html">forum</a>.</p> 
  <p>Additional documentation about model features by vbs:<a href="https://github.com/verybadsoldier/esp_rgbww_fhemmodule/wiki">GitHub Wiki</a>.</p> 
  <p>Additional documentation about firmware modifications vbs:<a href="https://github.com/verybadsoldier/esp_rgbww_firmware/wiki">GitHub Wiki</a>.</p> 
  <br><br> 
 
  <a name="LedControllerdefine"></a> 
  <b>Define</b> 
  <ul> 
    <code>define &lt;name&gt; LedController [&lt;type&gt;] &lt;ip-or-hostname&gt;</code> 
    <br><br> 
 
      Example: 
      <ul> 
      <code>define LED_Stripe LedController 192.168.1.11</code><br> 
    </ul> 
  </ul> 
  <br> 
   
  <a name="LedControllerset"></a> 
  <b>Set</b> 
  <ul> 
    <li> 
      <p><code>set &lt;name&gt; <b>on</b> [ramp] [q]</code></p> 
      <p>Turns on the device. It is either chosen 100% White or the color defined by the attribute "defaultColor".</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>off</b> [ramp] [q]</code></p> 
      <p>Turns off the device.</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>dim</b> &lt;level&gt; [ramp] [q]</code></p> 
      <p>Sets the brightness to the specified level (0..100).<br /> 
      This command also maintains the preset color even with "dim 0" (off) and then "dim xx" (turned on) at.  
      Therefore, it represents an alternative form to "off" / "on". The latter would always choose the "default color".</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
  <li> 
      <p><code>set &lt;name&gt; <b>dimup / dimdown</b> &lt;level&gt; [ramp] [q]</code></p> 
      <p>Increases / decreases the brightness by the given value.<br /> 
      This command also maintains the preset color even with turning it all the way to 0 (off) and back up.  
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
    <li> 
    <li> 
      <p><code>set &lt;name&gt; <b>hsv</b> &lt;H,S,V&gt; [ramp] [l|q]</code></p> 
          <p>Sets color, saturation and brightness in the HSV color space. If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current color to the newly set. 
          <ul><i>For example, sets a saturated blue with half brightness:</i><br /><code>set LED_Stripe hsv 240,100,50</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
       
      <li> 
      <p><code>set &lt;name&gt; <b>hue</b> &lt;value&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color angle (0..360) in the HSV color space. If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current color to the newly set. 
          <ul><i>For example, changing only the hue with a transition of 5 seconds:</i><br /><code>set LED_Stripe hue 180 5</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>sat</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Sets the saturation in the HSV color space to the specified value (0..100). If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current saturation to the newly set. 
          <ul><i>For example, changing only the saturation with a transition of 5 seconds:</i><br /><code>set LED_Stripe sat 60 5</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>val</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Sets the brightness to the specified value (0..100). It's the same as cmd <b>dim</b>.</p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>rotate</b> &lt;angle&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color in the HSV color space by addition of the specified angle to the current color. 
          <ul><i>For example, changing color from current green to blue:</i><br /><code>set LED_Stripe rotate 120</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>rgb</b> &lt;RRGGBB&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color in the RGB color space.<br> 
          Currently RGB values will be converted into HSV to make use of the internal color compensation of the LedController.</p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>update</b></code></p> 
          <p>Gets the current HSV color from the LedController.</p> 
      </li> 
       
      <p><b>Meaning of Flags</b></p> 
      Certain commands (set) can be marked with special flags. 
      <p> 
      <ul> 
        <li>ramp:  
            <ul> 
              Time in seconds for a soft color or brightness transition. The soft transition starts at the currently visible color and is calculated for the specified. 
            </ul> 
        </li> 
        <li>l:  
            <ul> 
              (long). A smooth transition to another color is carried out in the HSV color space on the "long" way. 
              A transition from red to green then leads across magenta, blue, and cyan. 
            </ul> 
        </li> 
        <li>q:  
            <ul> 
              (queue). Commands with this flag are cached in an internal queue of the LedController and will not run before the currently running soft transitions have been processed.  
              Commands without the flag will be processed immediately. In this case all running transitions are stopped immediately and the queue will be cleared. 
            </ul> 
        </li> 
       
  </ul> 
  <br> 
 
  <a name="LedControllerattr"></a> 
  <b>Attributes</b> 
  <ul> 
    <li><a name="defaultColor">defaultColor</a><br> 
    <code>attr &ltname&gt <b>defaultColor</b> &ltH,S,V&gt</code><br> 
    Specify the light color in HSV which is selected at "on". Default is white.</li> 
 
    <li><a name="defaultRamp">defaultRamp</a><br> 
    Time in milliseconds. If this attribute is set, a smooth transition is always implicitly generated if no ramp in the set is indicated.</li> 
 
    <li><a name="colorTemp">colorTemp</a><br> 
    </li>

    <li><a name="slaves">slaves</a><br> 
    List of slave device names seperated by whitespacs. All set-commands will be forwarded to the slave devices. Example: "wz_lampe1 sz_lampe2"
    An offset for the HSV values can be applied for each slave device. Syntax: &lt;slave&gt;:&lt;offset_h&gt;,&lt;offset_s&gt;,&lt;offset_v&gt;
    </li> 
  </ul> 
  <p><b>Colorpicker for FhemWeb</b> 
    <ul> 
      <p> 
      In order for the Color Picker can be used in <a href="#FHEMWEB">FhemWeb</a> following attributes need to be set: 
      <p> 
      <li> 
         <code>attr &ltname&gt <b>webCmd</b> rgb</code> 
      </li> 
      <li> 
         <code>attr &ltname&gt <b>widgetOverride</b> rgb:colorpicker,rgb</code> 
      </li> 
    </ul> 
  <br> 
 
</ul> 
 
=end html 
=cut
