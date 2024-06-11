#!/usr/bin/perl -s 
#
# THOR Thunderstorm Collector
# Florian Roth
# v0.1
# April 2021
#
# Requires LWP::UserAgent
#   - on Linux: apt-get install libwww-perl
#   - other: perl -MCPAN -e 'install Bundle::LWP' 
#
# Usage examples:
#   $> perl thunderstorm-collector.pl -- -s thunderstorm.internal.net
#   $> perl thunderstorm-collector.pl -- --dir / --server thunderstorm.internal.net

use warnings;
use strict;
use Getopt::Long;
use LWP::UserAgent;
use File::Spec::Functions qw( catfile );

use Cwd; # module for finding the current working directory 

# Configuration
our $debug = 0;
my $targetdir = "/";
my $server = "";
my $port = 8080;
my $scheme = "http";
our $max_age = 3;       # in days
our $max_size = 10;     # in megabytes
our @skipElements = map { qr{$_} } ('^\/proc', '^\/mnt', '\.dat$', '\.npm');
our @hardSkips = ('/proc', '/dev', '/sys');

# Command Line Parameters
GetOptions("dir=s"      => \$targetdir,  # same for --dir or -d
           "server=s"   => \$server,     # same for --server or -s
           "port=i"     => \$port,       # same for --port or -p
           "debug"      => \$debug       # --debug
          );

# Composed Values
our $api_endpoint = "$scheme://$server:$port/api/checkAsync";
our $current_date = time;

# Stats
our $num_submitted = 0;
our $num_processed = 0;

# Objects
our $ua;

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
            if ( $debug ) { print "[DEBUG] Checking $filepath ...\n"; }
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
        if ( ( $size / 1024 / 1024 ) gt $max_size ) {
            if ( $debug ) { print "[DEBUG] Skipping file due to file size $filepath\n"; }
            next;
        }
        # Age
        #print("MDATE: $mdate CURR_DATE: $current_date\n");
        if ( $mdate lt ( $current_date - ($max_age * 86400) ) ) {
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
        eval {
            my $req = $ua->post($api_endpoint,
                Content_Type => 'form-data',
                Content => [
                    "file" => [ $filepath ],
                ],
            );
            $successful = $req->is_success;
            $num_submitted++;
            print "\nError: ", $req->status_line unless $successful;
        } or do {
            my $error = $@ || 'Unknown failure';
            warn "Could not submit '$filepath' - $error";
        };
        if ($successful) {
            last;
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
# Start the walk
&processDir($targetdir);

# End message
my $end_date = time;
my $minutes = int(( $end_date - $current_date ) / 60);
print "Thunderstorm Collector Run finished (Checked: $num_processed Submitted: $num_submitted Minutes: $minutes)\n";
