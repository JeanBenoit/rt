# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
#  
# This software is Copyright (c) 1996-2008 Best Practical Solutions, LLC 
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
package RT::Condition::ReopenTicket;

use strict;
use warnings;

use base 'RT::Condition::Generic';


=head2 IsApplicable

If the ticket was repopened, ie status was changed from any inactive status to
an active. See F<RT_Config.pm> for C<ActiveStatuses> and C<InactiveStatuses>
options.

=cut

sub IsApplicable {
    my $self = shift;

    my $txn = $self->TransactionObj;
    return 0 unless $txn->Type eq "Status" ||
        ( $txn->Type eq "Set" && $txn->Field eq "Status" );

    my $queue = $self->TicketObj->QueueObj;
    return 0 unless $queue->IsInactiveStatus( $txn->OldValue );
    return 0 unless $queue->IsActiveStatus( $txn->NewValue );

    $RT::Logger->debug("Condition 'On Reopen' triggered "
        ."for ticket #". $self->TicketObj->id
        ." transaction #". $txn->id
    );

    return 1;
}

eval "require RT::Condition::ReopenTicket_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Condition/ReopenTicket_Vendor.pm});
eval "require RT::Condition::ReopenTicket_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Condition/ReopenTicket_Local.pm});

1;