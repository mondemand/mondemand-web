#!/usr/local/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Fcntl;
use File::Basename;
use File::Find;
use Time::HiRes qw( gettimeofday tv_interval );
use vars qw ($saved_dir);

my ( %GraphsById, %TemplatesById, %BoardsById ) = ( (), (), () );

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

sub Indexes_Save
{
    croak 'Indexes_Save(type, idx, name)'
        if ( scalar(@_) < 3 || scalar(@_) > 5 );
    my ( $type, $idx, $name, $regex, $niceregex ) = ( @_ );

    &Indexes_Load;

    # XXX Small race condition here..

    my $cnt = 0;
    while ( $cnt++ < 3 ) {
        last if (sysopen(LOCK, "${saved_dir}/LCK.index", &O_WRONLY|&O_EXCL|&O_CREAT));
        sleep 5;
    }
    close LOCK;
    # We try, but force the lock if necessary..

    if ( $type ne 'drraw' && !open(LOG, ">> ${saved_dir}/log") ) {
        &Error("Could not append log entry: $!\n");
        unlink "${saved_dir}/LCK.index";
        return 0;
    }
    if ( $name ne '' ) {
        # Hard to say why, but if these two ifs are combined,
        # Perl (5.6.1) bombs out with an "insecure dependency in open" error.
        if ( !open(INDEX, "> ${saved_dir}/index") ) {
            &Error("Could not save index: $!\n");
            unlink "${saved_dir}/LCK.index";
            close LOG unless ( $type eq 'drraw' );
            return 0;
        }
    }
    if ( $type ne 'drraw' ) {
        print LOG time ."|". $type . $idx ."|";
        print LOG $user;
        print LOG " [$ENV{REMOTE_ADDR}]" if ($user eq 'guest');
        print LOG "|$name\n";
        close LOG;
    }

    if ( $name eq '' ) {
        unlink "${saved_dir}/LCK.index";
        # No name means something was deleted
        return;
    }

    if ( $type eq 'g' ) {
        $GraphsById{$idx}{'Name'} = $name;
        if ( $level == 1 ) {
            $GraphsById{$idx}{'Owner'} = $user;
        } else {
            delete($GraphsById{$idx}{'Owner'});
        }
    }
    foreach $idx ( keys(%GraphsById) ) {
        print INDEX 'g' . $idx . ':' . $GraphsById{$idx}{'Name'} . "\n";
        print INDEX 'g' . $idx . '=' . $GraphsById{$idx}{'Owner'} . "\n"
            if ( defined($GraphsById{$idx}{'Owner'}) );
    }
    if ( $type eq 't' ) {
        $TemplatesById{$idx}{'Name'} = $name;
        $TemplatesById{$idx}{'Filter'} = $regex;
        $TemplatesById{$idx}{'Display'} = $niceregex;
        if ( $level == 1 ) {
            $TemplatesById{$idx}{'Owner'} = $user;
        } else {
            delete($TemplatesById{$idx}{'Owner'});
        }
    }
    foreach $idx ( keys(%TemplatesById) ) {
        print INDEX 't' . $idx . ':' . $TemplatesById{$idx}{'Name'} . "\n";
        print INDEX 'tfr' . $idx . ':' . $TemplatesById{$idx}{'Filter'} . "\n";
        print INDEX 'tdr' . $idx . ':' . $TemplatesById{$idx}{'Display'} ."\n";
        print INDEX 't' . $idx . '=' . $TemplatesById{$idx}{'Owner'} . "\n"
            if ( defined($TemplatesById{$idx}{'Owner'}) );
    }
    if ( $type eq 'd' ) {
        $BoardsById{$idx}{'Name'} = $name;
        delete($BoardsById{$idx}{'Template'});
        if ( !defined(param('dGrouped')) ) {
            my $item;
            foreach $item ( grep(/^[a-z]+_Seq$/, param()) ) {
                $item =~ s/_Seq//;
                if ( param("${item}_type") eq 'Base' ) {
                    next unless ( param("${item}_dname") =~ /^t/ );
                    $BoardsById{$idx}{'Filters'}{$item}{'Template'} = param("${item}_dname");
                    $BoardsById{$idx}{'Filters'}{$item}{'Template'} =~ s/^t//;
                    $BoardsById{$idx}{'Filters'}{$item}{'Filter'} = param("${item}_regex");
                    $BoardsById{$idx}{'Filters'}{$item}{'Display'} = param("${item}_row");
                }
            }
        }
        if ( $level == 1 ) {
            $BoardsById{$idx}{'Owner'} = $user;
        } else {
            delete($BoardsById{$idx}{'Owner'});
        }
    }
    foreach $idx ( keys(%BoardsById) ) {
        print INDEX 'd' . $idx . ':' . $BoardsById{$idx}{'Name'} . "\n";
        if ( defined($BoardsById{$idx}{'Filters'}) ) {
            my $item;
            foreach $item ( sort keys(%{$BoardsById{$idx}{'Filters'}}) ) {
                print INDEX "dtn${idx}:${item}:t"
                    . $BoardsById{$idx}{'Filters'}{$item}{'Template'} . "\n";
                print INDEX "dfr${idx}:${item}:"
                    . $BoardsById{$idx}{'Filters'}{$item}{'Filter'} . "\n";
                print INDEX "ddr${idx}:${item}:"
                    . $BoardsById{$idx}{'Filters'}{$item}{'Display'} . "\n";
            }
        }
        print INDEX 'd' . $idx . '=' . $BoardsById{$idx}{'Owner'} . "\n"
            if ( defined($BoardsById{$idx}{'Owner'}) );
    }
    close INDEX;

    unlink "${saved_dir}/LCK.index";
    return 1;
}
