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
use warnings;

package RT::ScripAction::Autoreply;
use base qw(RT::ScripAction::SendEmail);

=head2 Prepare

Set up the relevant recipients, then call our parent.

=cut


sub prepare {
    my $self = shift;
    $self->set_Recipients();
    $self->SUPER::prepare();
}

# {{{ sub set_Recipients

=head2 SetRecipients

Sets the recipients of this message to this ticket's Requestor.

=cut


sub set_Recipients {
    my $self=shift;

    push(@{$self->{'To'}}, $self->ticket_obj->Requestors->member_emails);
    
    return(1);
}

# }}}


# {{{ sub set_ReturnAddress 

=head2 SetReturnAddress

Set this message\'s return address to the apropriate queue address

=cut

sub set_ReturnAddress {
    my $self = shift;
    my %args = ( is_comment => 0,
		 @_
	       );
    
    my $replyto;
    if ($args{'is_comment'}) { 
	$replyto = $self->ticket_obj->queue_obj->comment_address || 
		     RT->Config->Get('comment_address');
    }
    else {
	$replyto = $self->ticket_obj->queue_obj->correspond_address ||
		     RT->Config->Get('correspond_address');
    }
    
    unless ($self->template_obj->MIMEObj->head->get('From')) {
	if (RT->Config->Get('UseFriendlyFromLine')) {
	    my $friendly_name = $self->ticket_obj->queue_obj->Description ||
		    $self->ticket_obj->queue_obj->name;
	    $friendly_name =~ s/"/\\"/g;
	    $self->set_header( 'From',
		        sprintf(RT->Config->Get('FriendlyFromLineFormat'), 
                $self->MIMEEncodeString( $friendly_name, RT->Config->Get('EmailOutputEncoding') ), $replyto),
	    );
	}
	else {
	    $self->set_header( 'From', $replyto );
	}
    }
    
    unless ($self->template_obj->MIMEObj->head->get('Reply-To')) {
	$self->set_header('Reply-To', "$replyto");
    }
    
}
  
# }}}

1;