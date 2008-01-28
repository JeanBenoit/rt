#!/opt/local/bin/perl
# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
#  
# This software is Copyright (c) 1996-2007 Best Practical Solutions, LLC 
#                                          <jesse@bestpractical.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/copyleft/gpl.html.
# 
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
# 
# END BPS TAGGED BLOCK }}}
use strict;

BEGIN {
    $ENV{'PATH'}   = '/bin:/usr/bin';                     # or whatever you need
    $ENV{'CDPATH'} = '' if defined $ENV{'CDPATH'};
    $ENV{'SHELL'}  = '/bin/sh' if defined $ENV{'SHELL'};
    $ENV{'ENV'}    = '' if defined $ENV{'ENV'};
    $ENV{'IFS'}    = '' if defined $ENV{'IFS'};

    use CGI qw(-private_tempfiles);    #bring this in before mason, to make sure we
                                   #set private_tempfiles

    die "RT does not support mod_perl 1.99. Please upgrade to mod_perl 2.0"
      if $ENV{'MOD_PERL'}
      and $ENV{'MOD_PERL'} =~ m{mod_perl/(?:1\.9)};

}

use lib ( "/home/jesse/svk/3.999-DANGEROUS/local/lib", "/home/jesse/svk/3.999-DANGEROUS/lib" );
use RT;

package RT::Mason;

use vars qw($Nobody $system_user $Handler $r);

#This drags in RT's config.pm
BEGIN {
    RT::load_config();
    if (RT->Config->Get('DevelMode')) { require Module::Refresh; }
}


{

    package HTML::Mason::Commands;
    use vars qw(%session);
}

use RT::Interface::Web;
use RT::Interface::Web::Handler;
$Handler = RT::Interface::Web::Handler->new(current_user => RT->Config->Get('MasonParameters'));

if ($ENV{'MOD_PERL'} && !RT->Config->Get('DevelMode')) {
    # Under static_source, we need to purge the component cache
    # each time we restart, so newer components may be reloaded.
    #
    # We can't do this in FastCGI or we'll blow away the component root _every_ time a new server starts
    # which happens every few hits.
    
    use File::Path qw( rmtree );
    use File::Glob qw( bsd_glob );
    my @files = bsd_glob("$RT::MasonDataDir/obj/*");
    rmtree([ @files ], 0, 1) if @files;
}

sub handler {
    ($r) = @_;

    local $SIG{__WARN__};
    local $SIG{__DIE__};

    if ($r->content_type =~ m/^httpd\b.*\bdirectory/i) {
        use File::Spec::Unix;
        # Our DirectoryIndex is always index.html, regardless of httpd settings
        $r->filename( File::Spec::Unix->catfile( $r->filename, 'index.html' ) );
    }
#    elsif (defined( $r->content_type )) {
        #$r->content_type !~ m!(^text/|\bxml\b)!i or return -1;
#    }

    Module::Refresh->refresh if RT->Config->Get('DevelMode');

    RT::Init();

    my %session;
    my $status;
    eval { $status = $Handler->handle_request($r) };
    if ($@) {
        Jifty->log->fatal($@);
    }

    undef(%session);

    RT::Interface::Web::Handler->CleanupRequest();

    return $status;
}

1;