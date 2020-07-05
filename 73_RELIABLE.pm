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

    if(@arguments != 3) {
	return "usage: RELIABLE <get_cmd> <set_cmd> <notify_cmd>";
    }

    $hash->{CMD_GET} = $arguments[0];
    $hash->{CMD_SET} = $arguments[1];
    $hash->{CMD_NOTIFY} = $arguments[2];

    $hash->{NOTIFYDEV} = "global";
    $hash->{RETRY_COUNT} = $RELIABLE_DEFAULT_RETRY_COUNT;
    $hash->{RETRY_INTERVAL} = $RELIABLE_DEFAULT_RETRY_INTERVAL;
    $hash->{TRY_NR} = 0;

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

    if($attrName eq "retryInterval") {
	if($cmd eq "del") {
	    $hash->{RETRY_INTERVAL} = $RELIABLE_DEFAULT_RETRY_INTERVAL;
	} elsif($cmd eq "set") {
	    if ($attrValue =~ /^\d+$/ && int($attrValue) > 10 && int($attrValue) < 3600) {
		$hash->{RETRY_INTERVAL} = int($attrValue);
	    } else {
		return "retryCount must be an integer in the range [10,3600]";
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

    my $tryNr = ++$hash->{TRY_NR};
    
    Log3 $hash->{NAME}, 5, "try set #$tryNr";
    $hash->{STATE} = "cmd_try_$tryNr";

    my $argString = join(" ", @{$hash->{SET_ARGS}});
    my $setCmd = ($hash->{CMD_SET} =~ s/\$val/$argString/re);
    Log3 $hash->{NAME}, 5, "set command: $setCmd";
    my $result = AnalyzeCommandChain(undef, $setCmd);

    if($result) {
	Log3 $hash->{NAME}, 5, "non-zero return code when executing set command: $result";
	$hash->{STATE} = "cmd_fail_hard";
	return;
    }

    # check the value in 5 seconds
    RELIABLE_SetTimer($hash, "RELIABLE_CheckVal_Timer", $RELIABLE_CHECK_DELAY);
}

sub RELIABLE_NotifyFail($) {
    my ($hash) = @_;
    
    my $result = AnalyzeCommandChain(undef, $hash->{CMD_NOTIFY});

    if($result) {
	Log3 $hash->{NAME}, 5, "non-zero return code when executing notify command: $result";
    }
}

sub RELIABLE_CheckVal($) {
    my ($hash) = @_;

    my $shouldVal = join(" ", @{$hash->{SET_ARGS}});

    if($hash->{CMD_GET} =~ /(.+):(.+)/) {
	# use readings val
	my $targetDevice = $1;
	my $targetReading = $2;

	my $isVal = ReadingsVal($targetDevice, $targetReading, undef);

	Log3 $hash->{NAME}, 4, "check val, is=$isVal, should=$shouldVal";

	if($isVal eq $shouldVal) {
	    Log3 $hash->{NAME}, 5, "end condition met";
	    $hash->{STATE} = "success";
	} else {
	    if($hash->{TRY_NR} < $hash->{RETRY_COUNT}) {
		# try again next time
		RELIABLE_SetTimer($hash, "RELIABLE_TrySet_Timer", $hash->{RETRY_INTERVAL} - $RELIABLE_CHECK_DELAY);
	    } else {
		# call notification function
		$hash->{STATE} = "cmd_fail_soft";
		RELIABLE_NotifyFail($hash);
	    }
	}
    }

    # cases other than checking reading values are not supported yet
}

sub RELIABLE_Set ($$@) {
    my ($hash, $name, $cmd, @args) = @_;

    if($cmd eq "?") {
	return "target";
    }

    if($cmd ne "target") {
	return "can only set 'target'";
    }
    
    $hash->{SET_ARGS} = \@args;
    $hash->{TRY_NR} = 0;
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
