#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2013-11-17 21:08:10 +0000 (Sun, 17 Nov 2013)
#
#  http://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying LICENSE file
#  

$DESCRIPTION = "Nagios Plugin to check a Redis server's running config against a given configuration file

Useful for checking

1. Configuration Compliance against a baseline
2. Puppet has correctly deployed revision controlled config version

Detects password in this order of priority (highest first):

1. --password command line switch
2. \$REDIS_PASSWORD environment variable (recommended)
3. requirepass setting in config file

Inspired by check_mysql_config.pl (also part of the Advanced Nagios Plugins Collection)";

$VERSION = "0.6";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils qw/:DEFAULT :regex/;
use HariSekhon::Redis;
#use Cwd 'abs_path';
use IO::Socket;

my $default_config_cmd = "config";
my $config_cmd = $default_config_cmd;

# REGEX
my @config_file_only = qw(
                           activerehashing
                           daemonize
                           databases
                           maxclients
                           pidfile
                           port
                           rdbcompression
                           rename-command
                           slaveof
                           syslog-.*
                           vm-.*
                       );

my @running_conf_only = qw(
                            maxmemory.*
                       );

my $default_config = "/etc/redis.conf";
my $conf = $default_config;

$host = "localhost";

my $no_warn_extra     = 0;
my $no_warn_missing   = 0;

our %options = (
    %redis_options,
    "C|config=s"    => [ \$conf,        "Redis config file (default: $default_config)" ],
);
delete $options{"precision=i"};

@usage_order = qw/host port password config/;
get_options();

$host       = validate_host($host);
$port       = validate_port($port);
$password   = validate_password($password) if $password;
$conf       = validate_file($conf, 0, "config");
validate_thresholds();

vlog2;
set_timeout();

vlog2 "reading redis config file";
my $fh = open_file $conf;
vlog3;
vlog3 "=====================";
vlog3 "  Redis config file";
vlog3 "=====================";
my %config;
my ($key, $value);
while(<$fh>){
    chomp;
    s/#.*//;
    next if /^\s*$/;
    s/^\s*//;
    s/\s*$//;
    debug "conf file:  $_";
    /^\s*([\w\.-]+)\s+(.+?)\s*$/ or quit "UNKNOWN", "unrecognized line in config file '$conf': '$_'. $nagios_plugins_support_msg";
    $key   = lc $1;
    $value = lc $2;
    if($key eq "dir"){
        # this checks the file system and returns undef when /var/lib/redis isn't found when checking from my remote Mac
        #$value = abs_path($value);
        # Redis live running server displays the dir without trailing slash unlike default config
        $value =~ s/\/+$//;
    } elsif ($key eq "requirepass"){
        $value = "<omitted>";
        unless($password){
            vlog2 "detected and using password from config file";
            $password = $2;
        }
    } elsif ($key eq "rename-command"){
        my @tmp = split(/\s+/, $value);
        # if rename-command config " " this block is never entered
        if(scalar @tmp == 2){
            if($tmp[0] eq "config"){
                $config_cmd = $tmp[1];
                $config_cmd =~ s/["'`]//g;
                quit "UNKNOWN", "config command was disabled in config file '$conf' using rename-command" unless $config_cmd;
            }
        }
    }
    if($value =~ /^(\d+(?:\.\d+)?)([KMGTP]B)$/i){
        $value = expand_units($1, $2);
    }
    vlog3 "config:  $key = $value";
    if($key eq "save"){
        if(defined($config{$key})){
            $value = "$config{$key} $value";
        }
    }
    $config{$key} = $value;
}
vlog3 "=====================";

if($config_cmd ne $default_config_cmd){
    vlog2 "\nfound alternative config command '$config_cmd' from config file '$conf'";
}
$config_cmd =~ /^([\w-]+)$/ || quit "UNKNOWN", "config command was set to a non alphanumeric string '$config_cmd', aborting, check config file '$conf' for 'rename-command CONFIG'";
$config_cmd = $1;
vlog2;

$status = "OK";

# API libraries don't support config command, using direct socket connect, will do protocol myself
#my $redis = connect_redis(host => $host, port => $port, password => $password) || quit "CRITICAL", "failed to connect to redis server '$hostport'";

vlog2 "getting running redis config from '$host:$port'";

my $ip = validate_resolvable($host);
vlog2 "resolved $host to $ip";

$/ = "\r\n";
vlog2 "connecting to redis server $ip:$port ($host)";
my $redis_conn = IO::Socket::INET->new (
                                    Proto    => "tcp",
                                    PeerAddr => $ip,
                                    PeerPort => $port,
                                    Timeout  => $timeout,
                                 ) or quit "CRITICAL", sprintf("Failed to connect to '%s:%s'%s: $!", $ip, $port, (defined($timeout) and ($debug or $verbose > 2)) ? " within $timeout secs" : "");

vlog2;
if($password){
    vlog2 "sending redis password";
    print $redis_conn "auth $password\r\n";
    my $output = <$redis_conn>;
    chomp $output;
    unless($output =~ /^\+OK$/){
        quit "CRITICAL", "auth failed, returned: $output";
    }
    vlog2;
}

vlog2 "sending redis command: $config_cmd get *\n";
print $redis_conn "$config_cmd get *\r\n";
my $num_args = <$redis_conn>;
if($num_args =~ /^-|ERR/){
    chomp $num_args;
    $num_args =~ s/^-//;
    if($num_args =~ /operation not permitted/){
        quit "CRITICAL", "$num_args (authentication required? try --password)";
    } elsif ($num_args =~ /unknown command/){
        quit "CRITICAL", "$num_args (command disabled or renamed via 'rename-command' in config file '$conf'?)";
    } else {
        quit "CRITICAL", "error: $num_args";
    }
}
$num_args =~ /^\*(\d+)\r$/ or quit "CRITICAL", "unexpected response: $num_args";
$num_args = $1;
vlog2 sprintf("%s config settings offered by server\n", $num_args / 2);
my ($key_bytes, $value_bytes);
my %running_config;
vlog3 "========================";
vlog3 "  Redis running config";
vlog3 "========================";
my $null_configs_counter = 0;
foreach(my $i=0; $i < ($num_args / 2); $i++){
    $key_bytes  = <$redis_conn>;
    chomp $key_bytes;
    debug "key bytes:  $key_bytes";
    $key_bytes =~ /^\$(\d+)$/ or quit "UNKNOWN", "protocol error, invalid key bytes line received: $key_bytes";
    $key_bytes = $1;
    $key        = <$redis_conn>;
    chomp $key;
    debug "key:        $key";
    $key   = lc $key;
    ($key_bytes eq length($key)) or quit "UNKNOWN", "protocol error, num bytes does not match length of argument for $key ($key_bytes bytes expected, got " . length($key) . ")";
    $value_bytes = <$redis_conn>;
    chomp $value_bytes;
    debug "data bytes: $value_bytes";
    $value_bytes =~ /^\$(-?\d+)$/ or quit "UNKNOWN", "protocol error, invalid data bytes line received: $value_bytes";
    $value_bytes = $1;
    if($value_bytes == -1){
        $null_configs_counter++;
        next;
    }
    $value       = <$redis_conn>;
    chomp $value;
    $value = lc $value;
    ($value_bytes eq length($value)) or quit "UNKNOWN", "protocol error, num bytes does not match length of argument for $value ($value_bytes bytes expected, got " . length($value) . ")";
    if($key eq "requirepass"){
        $value = "<omitted>";
    }
    debug "data:       $value";
    vlog3 "running config:  $key=$value";
    if(defined($running_config{$key})){
        quit "UNKNOWN", "duplicate running config key detected. $nagios_plugins_support_msg";
    }
    $running_config{$key} = $value;
}
vlog3 "========================";
plural $null_configs_counter;
vlog2 sprintf("%s config settings parsed from server, %s null config$plural skipped\n", scalar keys %running_config, $null_configs_counter);
vlog3 "========================";

unless(($num_args/2) == ((scalar keys %running_config) + $null_configs_counter)){
    quit "UNKNOWN", "mismatch on number of config settings expected and parsed";
}

my @missing_config;
my @mismatched_config;
my @extra_config;
foreach my $key (sort keys %config){
    unless(defined($running_config{$key})){
        if(grep { $key =~ /^$_$/ } @config_file_only){
            vlog3 "skipping: $key (config file only)";
            next;
        } else {
            push(@missing_config, $key);
        }
        next;
    }
    unless($config{$key} eq $running_config{$key}){
        push(@mismatched_config, $key);
    }
}

foreach my $key (sort keys %running_config){
    unless(defined($config{$key})){
        if(grep { $key =~ /^$_$/ } @running_conf_only){
            vlog3 "skipping: $key (running config only)";
        } else {
            push(@extra_config, $key);
        }
    }
}

$msg = "";
if(@mismatched_config){
    critical;
    #$msg .= "mismatched config: ";
    foreach(sort @mismatched_config){
        $msg .= "$_ value mismatch '$config{$_}' in config vs '$running_config{$_}' live on server, ";
    }
}
if((!$no_warn_missing) and @missing_config){
    warning;
    $msg .= "config missing on running server: ";
    foreach(sort @missing_config){
        $msg .= "$_, ";
    }
    $msg =~ s/, $//;
    $msg .= ", ";
}
if((!$no_warn_extra) and @extra_config){
    warning;
    $msg .= "extra config found on running server: ";
    foreach(sort @extra_config){
        $msg .= "$_=$running_config{$_}, ";
    }
    $msg =~ s/, $//;
    $msg .= ", ";
}

$msg = sprintf("%d config values tested from config file '%s', %s", scalar keys %config, $conf, $msg);
$msg =~ s/, $//;

vlog2;
quit $status, $msg;
