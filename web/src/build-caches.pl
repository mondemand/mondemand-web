#!/usr/local/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Fcntl;
use File::Basename;
use File::Find;
use Time::HiRes qw( gettimeofday tv_interval );

# Configuration variable declarations, and default settings
use vars qw ( $title $header $footer
              %datadirs $dsfilter_def @rranames %rranames $vrefresh $drefresh
              @dv_def @dv_name @dv_secs $gformat $maxtime $crefresh
              $use_rcs $use_pnp4nagios
              $saved_dir $clean_cache $tmp_dir $ERRLOG %users
              %Index $IndexMax $icon_new $icon_closed $icon_open $icon_text
              $icon_help $icon_bug $icon_link
              %colors
              $CSS $CSS2 $bgColor $rrdcached_sock );

# Cache refresh time (seconds)
$crefresh = 3600;

my ( @rrdfiles, @evtfiles ) = ( (), () );
my ( %GraphsById, %TemplatesById, %BoardsById ) = ( (), (), () );
#my ( %TMPL ) = ( () );

# The configuration file is expected to be found in the same directory
# as drraw itself.  You may customize this to be elsewhere.
my $config = (dirname($0) =~ /(.*)/)[0] . "/drraw.conf"; # Untaint

# Now load the user configuration
unless ( do $config ) {
  my $err = ( $@ ne '' ) ? "$@" : "$!";
  die "Error loading configuration file: $config : $err\n";
}

sub Indexes_Load
{
    my $cnt = 0;
    while ( $cnt++ < 3 ) {
        last if (sysopen(LOCK, "${saved_dir}/LCK.index", &O_WRONLY|&O_EXCL|&O_CREAT));
        sleep 5;
    }
    close LOCK;
    # We try, but force the lock if necessary..

    if ( -f "${saved_dir}/index" ) {
        open INDEX, "< ${saved_dir}/index"
            or die "Could not load saved index: $!\n";
        while (<INDEX>) {
            chomp;
            if ( /^g(\d+\.\d+):(.+)$/ ) {
                $GraphsById{$1}{'Name'} = $2 if ( -f "${saved_dir}/g${1}" );
            } elsif ( /^g(\d+\.\d+)=(.*)$/ ) {
                $GraphsById{$1}{'Owner'} = $2 if ( -f "${saved_dir}/g${1}" );
            } elsif ( /^t(\d+\.\d+):(.+)$/ ) {
                $TemplatesById{$1}{'Name'} = $2 if ( -f "${saved_dir}/t${1}" );
            } elsif ( /^tfr(\d+\.\d+):(.*)$/ ) {
                $TemplatesById{$1}{'Filter'} = $2
                    if ( -f "${saved_dir}/t${1}" );
            } elsif ( /^tdr(\d+\.\d+):(.*)$/ ) {
                $TemplatesById{$1}{'Display'} = $2
                    if ( -f "${saved_dir}/t${1}" );
            } elsif ( /^drraw=(\d+)\/(.*)$/ ) {
                next;
            } elsif ( /^t(\d+\.\d+)=(.*)$/ ) {
                $TemplatesById{$1}{'Owner'} = $2
                    if ( -f "${saved_dir}/t${1}" );
            } elsif ( /^d(\d+\.\d+):(.+)$/ ) {
                $BoardsById{$1}{'Name'} = $2 if ( -f "${saved_dir}/d${1}" );
            } elsif ( /^dtn(\d+\.\d+):(\w+):t(\d+\.\d+)$/ ) {
                $BoardsById{$1}{'Filters'}{$2}{'Template'} = $3
                    if ( -f "${saved_dir}/d${1}" );
            } elsif ( /^dfr(\d+\.\d+):(\w+):(.*)$/ ) {
                $BoardsById{$1}{'Filters'}{$2}{'Filter'} = $3
                    if ( -f "${saved_dir}/d${1}" );
            } elsif ( /^ddr(\d+\.\d+):(\w+):(.*)$/ ) {
                $BoardsById{$1}{'Filters'}{$2}{'Display'} = $3
                    if ( -f "${saved_dir}/d${1}" );
            } elsif ( /^d(\d+\.\d+)=(.*)$/ ) {
                $BoardsById{$1}{'Owner'} = $2 if ( -f "${saved_dir}/d${1}" );
            } else {
                warn "Bad index entry: $_\n";
            }
        }
        close INDEX;
    }

    unlink "${saved_dir}/LCK.index";

}
    
sub Cache_Load
{
    if ( scalar(@rrdfiles) > 0 ) {
        warn "Cache may only be loaded once..\n";
        return;
    }
    if ( -f "${tmp_dir}/rrdfiles" ) {
        if ( time - (stat("${tmp_dir}/rrdfiles"))[9] < $crefresh ) {
            open CACHE, "< ${tmp_dir}/rrdfiles"
                or die "Could not load saved cache (rrdfiles): $!\n";
            while (<CACHE>) {
                chomp;
                push @rrdfiles, $_;
            }
            close CACHE;
        }
    }

    if ( scalar(@evtfiles) > 0 ) {
        warn "Cache may only be loaded once..\n";
        return;
    }

    if ( -f "${tmp_dir}/evtfiles" ) {
        if ( time - (stat("${tmp_dir}/evtfiles"))[9] < 3600 ) {
            open CACHE, "< ${tmp_dir}/evtfiles"
                or die "Could not load saved cache (evtfiles): $!\n";
            while (<CACHE>) {
                chomp;
                push @evtfiles, $_;
            }
            close CACHE;
        }
    }
    &DBFind if ( scalar (@rrdfiles) == 0);
}

sub Cache_Save
{
    if ( !open(CACHE, "> ${tmp_dir}/rrdfiles.$$") ) {
        &Error("Could not save cache (evtfiles): $!\n");
        return;
    }

    my $entry;
    foreach $entry ( @rrdfiles ) {
        print CACHE $entry . "\n";
    }
    close CACHE;
    if ( !rename("${tmp_dir}/rrdfiles.$$", "${tmp_dir}/rrdfiles") ) {
        unlink "${tmp_dir}/rrdfiles.$$";
        &Error("Could not save cache (evtfiles): $!\n");
    }

    if ( !open(CACHE, "> ${tmp_dir}/evtfiles.$$") ) {
        &Error("Could not save cache (evtfiles): $!\n");
        return;
    }

    foreach $entry ( @evtfiles ) {
        print CACHE $entry . "\n";
    }
    close CACHE;
    if ( !rename("${tmp_dir}/evtfiles.$$", "${tmp_dir}/evtfiles") ) {
        unlink "${tmp_dir}/evtfiles.$$";
        &Error("Could not save cache (evtfiles): $!\n");
    }
}

sub DBFind
{
  my $start = [gettimeofday()];
  warn "RRD File cache expired, rebuilding\n";
  @rrdfiles = ();
  @evtfiles = ();
  find({wanted=>\&DBFinder, no_chdir=>1, follow=>1,
        untaint=>1, # Untaint, lame...
        untaint_pattern=>qr|^([-+@\w./:]+)$|}, keys(%datadirs));
  Cache_Save;
  my $elapsed = tv_interval ($start);
  warn "Took $elapsed seconds to build rrd file cache\n";
}

sub DBFinder
{
    if ( -f $_ && ( /.\.rrd$/ || /.\.evt$/ ) ) {
        my $start;
        foreach $start ( keys(%datadirs) ) {
            if ( $_ =~ /^${start}\/(.+)$/ ) {
                my $end = $1;
                if ( $_ =~ /\.rrd$/ ) {
                    push @rrdfiles, $start . '//' . $end;
                } else {
                    push @evtfiles, $start . '//' . $end;
                }
                return;
            }
        }
        warn "DBFinder called for $_ which does not match any of \%datadirs: ". join(", ", keys(%datadirs)) ."\n";
        die "Something is wrong in DBFinder... (". $File::Find::dir .")\n";
    }
}


sub MatchLabel
{
  my ($search, $replace, $label) = @_;
  $label =~ s/.*\/\///;
  my $orig = $label;
  if ( $label =~ m/$search/ ) {
    $label = eval $replace;
    if ($label eq "") {
      $label = join (' - ', ($orig =~ /$search/));
    }
  } else {
    $label = "";
  }
  return $label;
}

sub TMPLFind
{
    die 'TMPLFind(filter, display)'
        unless ( scalar(@_) == 0 || scalar(@_) == 2 );
    my ( $ex, $nex ) = ( @_ );

    my $start = [gettimeofday()];
    my %once;
    my $Tmpl = {};
    return $Tmpl unless ( defined($ex) && $ex ne '' );
    my $label_search = qr($ex);
    my $label_replacement = "qq{$nex}";
    foreach my $base ( @rrdfiles ) {
      my $label = MatchLabel ($label_search, $label_replacement, $base);
      next if $label eq "";
      next if ( defined($once{$label}) );
      $once{$label} = 1;
      $Tmpl->{$base} = $label;
    }
    my $elapsed = tv_interval ($start);
    warn "Took $elapsed seconds to TMPLFind ($ex, $nex)\n";
    return $Tmpl;
}

sub TMPLFindByTemplate
{
  my ($template, $ex, $nex) = (@_);

  # UnTaint
  unless ($template =~ m/^([a-zA-Z0-9\._\-]+)$/) {
    die "bad arg\n";
  }
  $template = $1;

  my $template_cache_file = $tmp_dir . '/' ."cached-template-labels-$template";
  
  my $Tmpl;

  if ( ! -f $template_cache_file
       or (time - (stat($template_cache_file))[9] > 3600) )
  {
    warn "didn't find or cache expired for $template_cache_file, so creating\n";
    $Tmpl = TMPLFind ($ex, $nex);
    open (TEMPLATE, "> $template_cache_file")
      or die "Could not open $template_cache_file : $!\n";
    foreach my $f (keys %{$Tmpl}) {
      print TEMPLATE "$f\t".$Tmpl->{$f}."\n";
    }
    close TEMPLATE;
    `chown apache:apache $template_cache_file`;
    warn "wrote $template_cache_file\n";
  }
  else
  {
    warn "found cache $template_cache_file\n";
    open (TEMPLATE, "< $template_cache_file")
      or die "Could not open $template_cache_file : $!\n";
    while (my $line = <TEMPLATE>) {
      chomp $line;
      my ($f, @rest) = split /\t/, $line;
      my $rest = join ("\t", @rest);
      $Tmpl->{$f} = $rest;
    }
    close TEMPLATE;
  }
  return $Tmpl;
}

sub BuildTemplateLabelCacheFiles
{
  my @templates = keys %TemplatesById;
  foreach my $template (@templates) {
    my $filter = $TemplatesById{$template}{'Filter'};
    my $display = $TemplatesById{$template}{'Display'};
    my $Tmpl = TMPLFindByTemplate ($template, $filter, $display);
  }
}

my $start = [gettimeofday()];

# PHASE 1 - load current indices
my $load_start = [gettimeofday()];
Indexes_Load;
my $load_elapsed = tv_interval ($load_start);
warn "Took $load_elapsed seconds to load indices\n";

# PHASE 2 - load the cached rrd files, possibly refreshing it
my $cache_start = [gettimeofday()];
Cache_Load;
my $cache_elapsed = tv_interval ($cache_start);
warn "Took $cache_elapsed seconds to build rrd file list\n";

# PHASE 3 - load the template label cache files, possibly recreating them
my $build_start = [gettimeofday()];
BuildTemplateLabelCacheFiles;
my $build_elapsed = tv_interval ($build_start);
warn "Took $build_elapsed seconds to build template labels cache\n";

my $elapsed = tv_interval ($start);
warn "Took $elapsed seconds to run\n";

0;
