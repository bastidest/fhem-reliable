package main;

use strict;
use warnings;

my $RELIABLE_DEFAULT_RETRY_COUNT = 10;
my $RELIABLE_DEFAULT_RETRY_INTERVAL = 60;
my $RELIABLE_CHECK_DELAY = 5;

sub RELIABLE_Initialize($) {
    my ($hash) = @_;

    # Provider
    $hash->{DefFn}    = "RELIABLE_Define";
    $hash->{NotifyFn} = "RELIABLE_Notify";
    # $hash->{UndefFn}  = "RELIABLE_Undef";
    $hash->{SetFn}    = "RELIABLE_Set";
    $hash->{AttrFn}   = "RELIABLE_Attr";
    $hash->{AttrList} = "retryInterval retryCount";
}

sub RELIABLE_SetupAttrs($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $rc = AttrVal($name, "retryCount", undef);
    my $ri = AttrVal($name, "retryInterval", undef);

    if($rc) {
	$hash->{RETRY_COUNT} = $rc;
    }

    if($ri) {
	$hash->{RETRY_INTERVAL} = $ri;
    }
}

sub RELIABLE_Define($$) {
    my ($hash, $def) = @_;

    my($a, $h) = parseParams($def);
    my @arguments = @{$a}[2..$#{$a}];

    if(@arguments != 2) {
	return "usage: RELIABLE <target_device> <target_reading>";
    }

    $hash->{TARGET_DEVICE} = $arguments[0];
    $hash->{TARGET_READING} = $arguments[1];

    $hash->{NOTIFYDEV} = "global";
    $hash->{RETRY_COUNT} = $RELIABLE_DEFAULT_RETRY_COUNT;
    $hash->{RETRY_INTERVAL} = $RELIABLE_DEFAULT_RETRY_INTERVAL;

    RELIABLE_SetupAttrs($hash) if($init_done);

    return undef;
}

sub RELIABLE_Notify($$)
{
    my ($hash, $emitterHash) = @_;

    # Return without any further action if the module is disabled
    return "" if(IsDisabled($hash->{NAME})); 

    if($emitterHash->{NAME} eq "global") {
	my $events = deviceEvents($emitterHash, 1);
	if(grep(m/^INITIALIZED|REREADCFG$/, @{$events})) {
	    RELIABLE_SetupAttrs($hash);
	}
    }
}

sub RELIABLE_Attr($$$$) {
    my ($cmd, $name, $attrName, $attrValue) = @_;
    my $hash = $defs{$name};

    if($attrName eq "retryCount") {
	if($cmd eq "del") {
	    $hash->{RETRY_COUNT} = $RELIABLE_DEFAULT_RETRY_COUNT;
	} elsif($cmd eq "set") {
	    if ($attrValue =~ /^\d+$/ && int($attrValue) > 0 && int($attrValue) < 100) {
		$hash->{RETRY_COUNT} = int($attrValue);
	    } else {
		return "retryCount must be an integer in the range [0,100]";
	    }
	}
    }

    return undef;
}

sub RELIABLE_SetTimer($$$) {
    my ($hash, $targetFn, $delta) = @_;
    my $name = $hash->{NAME};
    my $now = gettimeofday();

    my $nextTrigger = $now + $delta;
    $hash->{TRIGGERTIME} = $nextTrigger;
    $hash->{TRIGGERTIME_FMT} = FmtDateTime($nextTrigger);
    
    RemoveInternalTimer("update:$name");
    InternalTimer($nextTrigger, $targetFn, "update:$name", 0);
    
    Log3 $name, 5, "$name: will call $targetFn in " . 
	sprintf ("%.1f", $nextTrigger - $now) . " seconds at $hash->{TRIGGERTIME_FMT}";
}

sub RELIABLE_TrySet($) {
    my ($hash) = @_;

    Log3 $hash->{NAME}, 3, "try set";

    my $argString = join(" ", @{$hash->{SET_ARGS}});
    my $setCmd = "set $hash->{TARGET_DEVICE} $hash->{TARGET_READING} $argString";
    Log3 $hash->{NAME}, 3, "set command: $setCmd";
    my $result = AnalyzeCommandChain(undef, $setCmd);

    if($result) {
	Log3 $hash->{NAME}, 3, "non-zero return code when executing set command: $result";
	$hash->{STATE} = "cmd_fail_hard";
	return;
    }

    # check the value in 5 seconds
    RELIABLE_SetTimer($hash, "RELIABLE_CheckVal_Timer", $RELIABLE_CHECK_DELAY);
}

sub RELIABLE_IsStateDone($) {
    my ($hash) = @_;

    Log3 $hash->{NAME}, 3, "check val";

    # try again next time
    RELIABLE_SetTimer($hash, "RELIABLE_TrySet_Timer", $hash->{RETRY_INTERVAL} - $RELIABLE_CHECK_DELAY);
}

sub RELIABLE_CheckVal($) {
    my ($hash) = @_;

    Log3 $hash->{NAME}, 3, "check val";

    # try again next time
    RELIABLE_SetTimer($hash, "RELIABLE_TrySet_Timer", $hash->{RETRY_INTERVAL} - $RELIABLE_CHECK_DELAY);
}

sub RELIABLE_Set ($$@) {
    my ($hash, $name, $cmd, @args) = @_;

    if($cmd eq "?") {
	return $hash->{TARGET_READING};
    }

    if($cmd ne $hash->{TARGET_READING}) {
	return "can only set '$hash->{TARGET_READING}'";
    }
    
    $hash->{SET_ARGS} = \@args;
    RELIABLE_TrySet($hash);

    return undef;
}

sub RELIABLE_TrySet_Timer($) {
    my ($calltype, $name) = split(':', $_[0]);
    my $hash = $defs{$name};

    RELIABLE_TrySet($hash);
}

sub RELIABLE_CheckVal_Timer($) {
    my ($calltype, $name) = split(':', $_[0]);
    my $hash = $defs{$name};

    RELIABLE_CheckVal($hash);
}

1;
