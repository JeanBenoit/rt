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
#
package RT::ScripAction::Notify;

use strict;
use warnings;

use base qw(RT::ScripAction::SendEmail);

use Mail::Address;

=head2 Prepare

Set up the relevant recipients, then call our parent.

=cut


sub prepare {
    my $self = shift;
    $self->set_Recipients();
    $self->SUPER::prepare();
}

=head2 SetRecipients

Sets the recipients of this meesage to Owner, Requestor, AdminCc, Cc or All. 
Explicitly B<does not> notify the creator of the transaction by default

=cut

sub set_Recipients {
    my $self = shift;

    my $ticket = $self->ticket_obj;

    my $arg = $self->Argument;
    $arg =~ s/\bAll\b/Owner,Requestor,AdminCc,Cc/;

    my ( @To, @PseudoTo, @Cc, @Bcc );


    if ( $arg =~ /\bOtherRecipients\b/ ) {
        if ( my $attachment = $self->transaction_obj->Attachments->first ) {
            push @Cc, map { $_->address } Mail::Address->parse(
                $attachment->get_header('RT-Send-Cc')
            );
            push @Bcc, map { $_->address } Mail::Address->parse(
                $attachment->get_header('RT-Send-Bcc')
            );
        }
    }

    if ( $arg =~ /\bRequestor\b/ ) {
        push @To, $ticket->Requestors->member_emails;
    }

    if ( $arg =~ /\bCc\b/ ) {

        #If we have a To, make the Ccs, Ccs, otherwise, promote them to To
        if (@To) {
            push ( @Cc, $ticket->Cc->member_emails );
            push ( @Cc, $ticket->queue_obj->Cc->member_emails  );
        }
        else {
            push ( @Cc, $ticket->Cc->member_emails  );
            push ( @To, $ticket->queue_obj->Cc->member_emails  );
        }
    }

    if ( $arg =~ /\bOwner\b/ && $ticket->OwnerObj->id != RT->nobody->id ) {
        # If we're not sending to Ccs or requestors,
        # then the Owner can be the To.
        if (@To) {
            push ( @Bcc, $ticket->OwnerObj->email );
        }
        else {
            push ( @To, $ticket->OwnerObj->email );
        }

    }
    if ( $arg =~ /\bAdminCc\b/ ) {
        push ( @Bcc, $ticket->AdminCc->member_emails  );
        push ( @Bcc, $ticket->queue_obj->AdminCc->member_emails  );
    }

    if ( RT->Config->Get('UseFriendlyToLine') ) {
        unless (@To) {
            push @PseudoTo,
                sprintf RT->Config->Get('FriendlyToLineFormat'), $arg, $ticket->id;
        }
    }

    my $creator = $self->transaction_obj->creator_obj->email() ||'' ;

    #Strip the sender out of the To, Cc and AdminCc and set the 
    # recipients fields used to build the message by the superclass.
    # unless a flag is set 
    if (RT->Config->Get('NotifyActor')) {
        @{ $self->{'To'} }  = @To;
        @{ $self->{'Cc'} }  = @Cc;
        @{ $self->{'Bcc'} } = @Bcc;
    }
    else {
        @{ $self->{'To'} }  = grep { lc $_ ne lc $creator} @To;
        @{ $self->{'Cc'} }  = grep { lc $_ ne lc $creator} @Cc;
        @{ $self->{'Bcc'} } = grep { lc $_ ne lc $creator} @Bcc;
    }
    @{ $self->{'PseudoTo'} } = @PseudoTo;


}

1;