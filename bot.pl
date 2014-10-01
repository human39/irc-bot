#!/usr/bin/env perl

use warnings;
use strict;

package Bot;
use base qw( Bot::BasicBot );

# Basic Config. 
my $IMG_DIR  = "~/.tmp";
my $EXIF_KEYS = [qw( ImageSize FileSize MIMEType SecurityClassification OwnerName GPSLatitude GPSLongitude GPSAltitude GPSDateTime GPSProcessingMethod Copyright UserComment)]; 

# Binaries
my $WHATWEB = '/usr/bin/whatweb --color=never';

my $OPT = {
    debug => 0, 
    config => './irc-bot.ini', 
};

use Getopt::Long;
use WWW::Mechanize;
use Regexp::Common qw /URI/;
use String::ShellQuote;
use Proc::Daemon;
use URI::Find;
use Data::Dumper;
use File::Basename;
use Image::ExifTool ':Public';
use Mojo::UserAgent;
use URI::Encode qw(uri_encode);
use Config::IniFiles;

GetOptions(
    $OPT, 
    "debug!",   
    "config=s",   
);

# Configuration
my $INI = Config::IniFiles->new( -file => $OPT->{config});
die "Could not find or parse configuration files [ $OPT->{config} ]" unless $INI;

my $ME       =   $INI->val('general', 'botname'); 
die "Could not find the bot name in the configuration file." unless $ME;

my $SERVER   =   $INI->val('general', 'server'); 
die "Could not find servers in the configuration file." unless $SERVER;

my $CHANNELS = [ $INI->val('general', 'channel') ];
die "Could not find channels in the configuration file." unless $CHANNELS;

# Random insults
my @INSULTS  =   $INI->val('general', 'insults'); 

# If we're in debugging mode, make some changes.
if ($OPT->{debug}) {
    $ME       = 'testbot';
    $CHANNELS = ['#test'];
}

# daemonize.
Proc::Daemon::Init unless $OPT->{debug};

my %COMMAND_DISPATCH = (
    whatweb => \&_whatweb, 

    twitter => \&_twitter,
    t       => \&_twitter,

    lw      => \&_lmgtfy,

);

sub said {
    my ($self, $message) = @_;
    
    my $cmd;
    my @args;   

    if ($message->{body} =~ /^!/) {
        @args = split(/\s+/, $message->{body});
        $cmd = shift @args;
        $cmd =~ s/^!//g;
    }

    if ($cmd and $COMMAND_DISPATCH{$cmd} ) {
        $COMMAND_DISPATCH{$cmd}->($self, $message, \@args); 
    } elsif ($message->{body} =~ $RE{URI}{HTTP}{-scheme=>qr/https?/}) {
        $self->_fetch_web_title($message);
    }
}

# Bot Commands.

# Make a call to whatweb, a useful program that tells you a lot about a
# website.
sub _whatweb {
    my ($self, $message, $args) = @_;

    my $d = $args->[0];
    
    if ($d !~ $RE{URI}{HTTP}{-scheme=>qr/https?/}) {
        return $self->error($message->{channel}, "That does *NOT* look like a URL");
    }

    my $domain = shell_quote $d;
    my $data = `$WHATWEB $domain`;
    return $self->error($message->{channel}, "whatweb could not resolve [$domain]") if !$data;
    $self->say({
        channel => $message->{channel},
        body    => $data,
    });

}

# yank the last few twitter posts for a user.
sub _twitter {
    my ($self, $message, $args) = @_;
    
    my $ua = Mojo::UserAgent->new;
    my $user = $args->[0];

    my $twitter_url = "https://twitter.com/$user";

    if ($twitter_url !~ $RE{URI}{HTTP}{-scheme=>qr/https?/}) {
        return $self->error($message->{channel}, "Something is wrong with that twitter user");
    }

    my @tweets = $ua->get($twitter_url)->res->dom->find('.stream-item')->each;

    if (!@tweets) {
        return $self->error($message->{channel}, "Could not find any tweets");
    }

    for my $t (@tweets) {

        my $relative_ts;
        my $text;

        eval {
            $relative_ts = $t->at(".js-short-timestamp")->all_text;
            $text = $t->at(".tweet-text")->all_text;
        };

        if ( $@ ) {
            print Dumper $@ if $OPT->{debug};
            return $self->error($message->{channel}, "Could not get tweet information");
        }

        my $msg = "[$user ($relative_ts)] $text";

        # Return the first one, for now.
        return $self->say({
           channel =>  $message->{channel},
            body    => $msg,
        });

    }
}

# LazyWeb, mojo's idea.
sub _lmgtfy {
    my ($self, $message, $args) = @_;
    my $lmgtfy_url = "http://lmgtfy.com/?q=";

    my $search_string = uri_encode(join(" ", @$args));
    
    return $self->say({
       channel =>  $message->{channel},
       body    =>  $lmgtfy_url . $search_string,
    });

}

 
# The typical, fetch the title for all the URLs posted.
sub _fetch_web_title {
    my ($self, $message) = @_;

    # Find all the urls in the chat.
    my @uris;
    my $finder = URI::Find->new(sub {
       my($uri) = shift;
       push @uris, $uri;
    });

    $finder->find(\$message->{body});

    my $m  = WWW::Mechanize->new(
                 agent => 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:25.0) Gecko/20100101 Firefox/25.0',
             );

    for my $uri (@uris) {

        eval {$m->get($uri)};

        if ( $@ ) {
            print Dumper $@ if $OPT->{debug};
            return $self->error($message->{channel}, "Fetching the title of [$uri] didn't work");
        }

        my $string_to_send;

        # Image
        if ($m->content_type =~ /^image\//) {

            # Grab image name.
            my $filename = basename($uri);
    
            my $epoch = time();        
            my $file_to_save = "$IMG_DIR/$epoch-$filename";

            eval { $m->save_content($file_to_save); };

            if ( $@ ) {
                print Dumper $@ if $OPT->{debug};
                return $self->error($message->{channel}, "Could not save image [$uri]");
            }

            my $exif = ImageInfo $file_to_save;

            if ($exif) {
                my @img_info;
                for my $k (@$EXIF_KEYS) {
                    push @img_info, "[$k] = $exif->{$k}" if $exif->{$k}; 
                }

                if (@img_info) {
                   $string_to_send = "Interesting EXIF data for [$uri] - " . join(", ", @img_info);
                } else {
                    return $self->error($message->{channel}, "No interesting EXIF data for [$uri]");
                }
            } else {
                return $self->error($message->{channel}, "Could not get EXIF data for [$uri]");
            }

        } else {
            my $title = $m->title;
            if (@uris > 1) {
                $string_to_send = "Title for [$uri]: $title";
            } else {
                $string_to_send = "Title: $title";
            }
        }

        $self->say({
           channel =>  $message->{channel},
            body    => $string_to_send,
        });

    }
}

sub help { "I'm annoying, and do nothing useful." }

sub error {
    my ($self, $chan, $error) = @_;
    chomp $error;

    if (@INSULTS) {
        my $random_insult = $INSULTS[ rand @INSULTS ];
        $error = "$error, $random_insult";
    }

    $self->say({
       channel => $chan,
       body    => $error,
    });
}

Bot->new(
   server   => $SERVER,
   channels => $CHANNELS,
   nick     => $ME,
)->run();
