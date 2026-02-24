#!/usr/bin/perl -s
#
# THOR Thunderstorm Collector
# Florian Roth
# v0.2
# September 2025
#
# Requires LWP::UserAgent
#   - on Linux: apt-get install libwww-perl
#   - other: perl -MCPAN -e 'install Bundle::LWP'
#
# Usage examples:
#   $> perl thunderstorm-collector.pl -- -s thunderstorm.internal.net
#   $> perl thunderstorm-collector.pl -- --dir / --server thunderstorm.internal.net
#   $> perl thunderstorm-collector.pl -- --dir / --server thunderstorm.internal.net --so "My Source"

use warnings;
use strict;
use Getopt::Long;
use LWP::UserAgent;
use File::Spec::Functions qw( catfile );
use Sys::Hostname;
use POSIX qw(strftime);

use Cwd; # module for finding the current working directory

# Configuration
our $debug = 0;
my $targetdir = "/";
my $server = "";
my $port = 8080;
my $scheme = "http";
my $source = "";
our $max_age = 3;       # in days
our $max_size = 10;     # in megabytes
our @skipElements = map { qr{$_} } ('^\/proc', '^\/mnt', '\.dat$', '\.npm');
our @hardSkips = ('/proc', '/dev', '/sys', '/run', '/snap', '/.snapshots');

# Command Line Parameters
GetOptions(
    "dir|d=s"      => \$targetdir,  # --dir or -d
    "server|s=s"   => \$server,     # --server or -s
    "port|p=i"     => \$port,       # --port or -p
    "source|so=s"  => \$source,     # --source or -so
    "debug"        => \$debug       # --debug
);

# Use Hostname as Source if not set
if ( $source eq "" ) {
    $source = hostname;
}
# URL-encode source parameter
sub urlencode {
    my $s = shift;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# Add Source to URL if available
if ( $source ne "" ) {
    print "[DEBUG] No source specified, using hostname: $source\n" if $debug;
    $source = "?source=" . urlencode($source);
}

# Composed Values
our $base_url = "$scheme://$server:$port";
our $api_endpoint = "$base_url/api/checkAsync$source";
our $current_date = time;
our $SCAN_ID = "";

# Stats
our $num_submitted = 0;
our $num_processed = 0;

# Objects
our $ua;

# Send a begin/end collection marker to /api/collection
# Returns scan_id from response, or "" if unsupported/failed
sub collection_marker {
    my ($marker_type, $scan_id, $stats_ref) = @_;
    my $marker_url = "$base_url/api/collection";

    my $timestamp = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
    my $src_escaped = $source;
    $src_escaped =~ s/[\\"]/\\$&/g;

    my $body = "{\"type\":\"$marker_type\",\"source\":\"$src_escaped\",\"collector\":\"perl/0.2\",\"timestamp\":\"$timestamp\"";
    $body .= ",\"scan_id\":\"$scan_id\"" if $scan_id;
    if ($stats_ref) {
        $body .= ",\"stats\":{";
        my @pairs;
        for my $k (keys %$stats_ref) { push @pairs, "\"$k\":$stats_ref->{$k}"; }
        $body .= join(",", @pairs) . "}";
    }
    $body .= "}";

    my $resp = eval {
        $ua->post($marker_url,
            "Content-Type" => "application/json",
            Content => $body,
        );
    };
    return "" unless $resp && $resp->is_success;

    my $resp_body = $resp->content;
    my $returned_id = "";
    if ($resp_body =~ /"scan_id"\s*:\s*"([^"]+)"/) {
        $returned_id = $1;
    }
    return $returned_id;
}

# Process Folders
sub processDir {
    my ($workdir) = shift;
    my ($startdir) = &cwd;
    # keep track of where we began
    chdir($workdir) or do { print "[ERROR] Unable to enter dir $workdir:$!\n"; return; };
    opendir(DIR, ".") or do { print "[ERROR] Unable to open $workdir:$!\n"; return; };

    my @names = readdir(DIR) or do { print "[ERROR] Unable to read $workdir:$!\n"; return; };
    closedir(DIR);

    foreach my $name (@names){
        next if ($name eq ".");
        next if ($name eq "..");

        #print("Workdir: $workdir Name: $name\n");
        my $filepath = catfile($workdir, $name);
        # Hard directory skips
        my $skipHard = 0;
        foreach ( @hardSkips ) {
            $skipHard = 1 if ( $filepath eq $_ );
        }
        next if $skipHard;

        # Is a Directory
        if (-d $filepath){
            #print "IS DIR!\n";
            # Skip symbolic links
            if (-l $filepath) { next; }
            # Process Dir
            &processDir($filepath);
            next;
        } else {
            # Skip symbolic links to files
            if (-l $filepath) { next; }
            if ( $debug ) { print "[DEBUG] Checking $filepath ...\n"; }
        }

        # Characteristics
        my $size = (stat($filepath))[7];
        my $mdate = (stat($filepath))[9];
        #print("SIZE: $size MDATE: $mdate\n");

        # Count
        $num_processed++;

        # Skip some files ----------------------------------------
        # Skip Folders / elements
        my $skipRegex = 0;
        # Regex Checks
        foreach ( @skipElements ) {
            if ( $filepath =~ $_ ) {
                if ( $debug ) { print "[DEBUG] Skipping file due to configured exclusion $filepath\n"; }
                $skipRegex = 1;
            }
        }
        next if $skipRegex;
        # Size
        if ( ( $size / 1024 / 1024 ) > $max_size ) {
            if ( $debug ) { print "[DEBUG] Skipping file due to file size $filepath\n"; }
            next;
        }
        # Age
        #print("MDATE: $mdate CURR_DATE: $current_date\n");
        if ( $mdate < ( $current_date - ($max_age * 86400) ) ) {
            if ( $debug ) { print "[DEBUG] Skipping file due to age $filepath\n"; }
            next;
        }

        # Submit
        &submitSample($filepath);

        chdir($startdir) or die "Unable to change back to dir $startdir:$!\n";
    }
}

sub submitSample {
    my ($filepath) = shift;
    print "[SUBMIT] Submitting $filepath ...\n";
    my $retry = 0;
    for ($retry = 0; $retry < 4; $retry++) {
        if ($retry > 0) {
            my $sleep_time = 2 << $retry;
            print "[SUBMIT] Waiting $sleep_time seconds to retry submitting $filepath ...\n";
            sleep($sleep_time)
        }
        my $successful = 0;
        my $is_503 = 0;
        my $retry_after = 30;
        eval {
            my $req = $ua->post($api_endpoint,
                Content_Type => 'form-data',
                Content => [
                    # Second element overrides the filename sent in Content-Disposition
                    "file" => [ $filepath, $filepath ],
                ],
            );
            $successful = $req->is_success;
            if (!$successful) {
                if ($req->code == 503) {
                    $is_503 = 1;
                    my $ra = $req->header('Retry-After');
                    if (defined $ra && $ra =~ /^\d+$/) {
                        $retry_after = int($ra);
                    }
                    print "[SUBMIT] Server busy (503), retrying in ${retry_after}s ...\n";
                } else {
                    print "\nError: ", $req->status_line, "\n";
                }
            }
        } or do {
            my $error = $@ || 'Unknown failure';
            warn "Could not submit '$filepath' - $error";
        };
        if ($successful) {
            $num_submitted++;
            last;
        }
        # For 503, use server-specified wait time instead of exponential backoff
        if ($is_503) {
            sleep($retry_after);
            next;
        }
    }
}

# MAIN ----------------------------------------------------------------
# Default Values
print "==============================================================\n";
print "    ________                __            __                  \n";
print "   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _    \n";
print "    / / / _ \\/ // / _ \\/ _  / -_) __(_--/ __/ _ \\/ __/  ' \\   \n";
print "   /_/ /_//_/\\_,_/_//_/\\_,_/\\__/_/ /___/\\__/\\___/_/ /_/_/_/   \n";
print "                                                              \n";
print "   Florian Roth, Nextron Systems GmbH, 2021                   \n";
print "                                                              \n";
print "==============================================================\n";
print "Target Directory: '$targetdir'\n";
print "Thunderstorm Server: '$server'\n";
print "Thunderstorm Port: '$port'\n";
print "Using API Endpoint: $api_endpoint\n";
print "Maximum Age of Files: $max_age\n";
print "Maximum File Size: $max_size\n";
print "\n";

# Instanciate an object
$ua = LWP::UserAgent->new;

print "Starting the walk at: $targetdir ...\n";

# Send collection begin marker
$SCAN_ID = collection_marker("begin", "", undef);
if ($SCAN_ID) {
    print "[INFO] Collection scan_id: $SCAN_ID\n";
    $api_endpoint .= "&scan_id=" . urlencode($SCAN_ID);
}

# Start the walk
&processDir($targetdir);

# Send collection end marker with stats
my $end_date = time;
my $elapsed = $end_date - $current_date;
collection_marker("end", $SCAN_ID, {
    scanned  => $num_processed,
    submitted => $num_submitted,
    elapsed_seconds => $elapsed,
});

my $minutes = int( $elapsed / 60 );
print "Thunderstorm Collector Run finished (Checked: $num_processed Submitted: $num_submitted Minutes: $minutes)\n";
