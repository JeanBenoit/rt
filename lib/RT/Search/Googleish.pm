
# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
# 
# This software is Copyright (c) 1996-2009 Best Practical Solutions, LLC
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
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
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

=head1 NAME

  RT::Search::Googlish

=head1 SYNOPSIS

=head1 DESCRIPTION

Use the argument passed in as a "Google-style" set of keywords

=head1 METHODS




=cut

package RT::Search::Googleish;

use strict;
use warnings;
use base qw(RT::Search);

use Regexp::Common qw/delimited/;
my $re_delim = qr[$RE{delimited}{-delim=>qq{\'\"}}];

# sub _Init {{{
sub _Init {
    my $self = shift;
    my %args = @_;

    $self->{'Queues'} = delete($args{'Queues'}) || [];
    $self->SUPER::_Init(%args);
}
# }}}

# {{{ sub Describe 
sub Describe  {
  my $self = shift;
  return ($self->loc("No description for [_1]", ref $self));
}
# }}}

# {{{ sub QueryToSQL
sub QueryToSQL {
    my $self     = shift;
    my $query    = shift || $self->Argument;

    my @keywords = grep length, map { s/^\s+//; s/\s+$//; $_ }
        split /((?:fulltext:)?$re_delim|\s+)/o, $query;

    my (
        @tql_clauses,  @owner_clauses, @queue_clauses,
        @user_clauses, @id_clauses,    @status_clauses
    );
    my ( $Queue, $User );
    for my $key (@keywords) {

        # Is this a ticket number? If so, go to it.
        # But look into subject as well
        if ( $key =~ m/^\d+$/ ) {
            push @id_clauses, "id = '$key'", "Subject LIKE '$key'";
        }

        # if it's quoted string then search it "as is" in subject or fulltext
        elsif ( $key =~ /^(fulltext:)?($re_delim)$/io ) {
            if ( $1 ) {
                push @tql_clauses, "Content LIKE $2";
            } else {
                push @tql_clauses, "Subject LIKE $2";
            }
        }

        elsif ( $key =~ /^fulltext:(.*?)$/i ) {
            $key = $1;
            $key =~ s/['\\].*//g;
            push @tql_clauses, "Content LIKE '$key'";

        }

        elsif ( $key =~ /\w+\@\w+/ ) {
            push @user_clauses, "Requestor LIKE '$key'";
        }

        # Is there a status with this name?
        elsif (
            $Queue = RT::Queue->new( $self->TicketsObj->CurrentUser )
            and $Queue->IsValidStatus($key)
          )
        {
            push @status_clauses, "Status = '" . $key . "'";
        }

        # Is there a queue named $key?
        elsif ( $Queue = RT::Queue->new( $self->TicketsObj->CurrentUser )
            and $Queue->Load($key) )
        {
            my $quoted_queue = $Queue->Name;
            $quoted_queue =~ s/'/\\'/g;
            push @queue_clauses, "Queue = '$quoted_queue'";
        }

        # Is there a owner named $key?
        elsif ( $User = RT::User->new( $self->TicketsObj->CurrentUser )
            and $User->Load($key)
            and $User->Privileged )
        {
            push @owner_clauses, "Owner = '" . $User->Name . "'";
        }

        # Else, subject must contain $key
        else {
            $key =~ s/['\\].*//g;
            push @tql_clauses, "Subject LIKE '$key'";
        }
    }

    # restrict to any queues requested by the caller
    for my $queue (@{ $self->{'Queues'} }) {
        my $QueueObj = RT::Queue->new($self->TicketsObj->CurrentUser);
        $QueueObj->Load($queue) or next;
        my $quoted_queue = $QueueObj->Name;
        $quoted_queue =~ s/'/\\'/g;
        push @queue_clauses, "Queue = '$quoted_queue'";
    }

    push @tql_clauses, join( " OR ", sort @id_clauses );
    push @tql_clauses, join( " OR ", sort @owner_clauses );
    if ( ! @status_clauses ) {
        push @tql_clauses, join( " OR ", map "Status = '$_'", RT::Queue->ActiveStatusArray());
    } else {
        push @tql_clauses, join( " OR ", sort @status_clauses );
    }
    push @tql_clauses, join( " OR ", sort @user_clauses );
    push @tql_clauses, join( " OR ", sort @queue_clauses );
    @tql_clauses = grep { $_ ? $_ = "( $_ )" : undef } @tql_clauses;
    return join " AND ", sort @tql_clauses;
}
# }}}

# {{{ sub Prepare
sub Prepare  {
  my $self = shift;
  my $tql = $self->QueryToSQL($self->Argument);

  $RT::Logger->debug($tql);

  $self->TicketsObj->FromSQL($tql);
  return(1);
}
# }}}

eval "require RT::Search::Googleish_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Search/Googleish_Vendor.pm});
eval "require RT::Search::Googleish_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Search/Googleish_Local.pm});

1;
