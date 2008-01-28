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
# Portions Copyright 2000 Tobias Brox <tobix@cpan.org>

package RT::ScripAction::SendEmail;

use strict;
use warnings;

use base qw(RT::ScripAction::Generic);

use MIME::Words qw(encode_mimeword);

use RT::EmailParser;
use RT::Interface::Email;
use Mail::Address;

=head1 name

RT::ScripAction::SendEmail - An Action which users can use to send mail 
or can subclassed for more specialized mail sending behavior. 
RT::ScripAction::AutoReply is a good example subclass.

=head1 SYNOPSIS

  require RT::ScripAction::SendEmail;
  @ISA  = qw(RT::ScripAction::SendEmail);


=head1 DESCRIPTION

Basically, you create another module RT::ScripAction::YourAction which ISA
RT::ScripAction::SendEmail.

=head1 METHODS

=head2 clean_slate

Cleans class-wide options, like L</SquelchMailTo> or L</AttachTickets>.

=cut

sub clean_slate {
    my $self = shift;
    $self->SquelchMailTo( undef );
    $self->AttachTickets( undef );
}

=head2 Commit

Sends the prepared message and writes outgoing record into DB if the feature is
activated in the config.

=cut

sub commit {
    my $self = shift;

    my $message = $self->template_obj->MIMEObj;

    my $orig_message;
    if ( RT->Config->Get('RecordOutgoingEmail') && RT->Config->Get('GnuPG')->{'Enable'} ) {
        # it's hacky, but we should know if we're going to crypt things
        my $attachment = $self->transaction_obj->Attachments->first;

        my %crypt;
        foreach my $argument ( qw(Sign Encrypt) ) {
            if ( $attachment && defined $attachment->get_header("X-RT-$argument") ) {
                $crypt{$argument} = $attachment->get_header("X-RT-$argument");
            } else {
                $crypt{$argument} = $self->ticket_obj->queue_obj->$argument();
            }
        }
        if ( $crypt{'Sign'} || $crypt{'Encrypt'} ) {
            $orig_message = $message->dup;
        }
    }


    my ($ret) = $self->SendMessage( $message );
    if ( $ret > 0 && RT->Config->Get('RecordOutgoingEmail') ) {
        if ( $orig_message ) {
            $message->attach(
                Type        => 'application/x-rt-original-message',
                Disposition => 'inline',
                Data        => $orig_message->as_string,
            );
        }
        $self->RecordOutgoingMailTransaction( $message );
    }
    return (abs $ret);
}

=head2 Prepare

Builds an outgoing email we're going to send using scrip's template.

=cut

sub prepare {
    my $self = shift;

    my ( $result, $message ) = $self->template_obj->Parse(
        Argument       => $self->Argument,
        ticket_obj      => $self->ticket_obj,
        transaction_obj => $self->transaction_obj
    );
    if ( !$result ) {
        return (undef);
    }

    my $MIMEObj = $self->template_obj->MIMEObj;

    # Header
    $self->set_RTSpecialHeaders();

    $self->RemoveInappropriateRecipients();

    my %seen;
    foreach my $type qw(To Cc Bcc) {
        @{ $self->{ $type } } =
            grep defined && length && !$seen{ lc $_ }++,
                @{ $self->{ $type } };
    }

    # Go add all the Tos, Ccs and Bccs that we need to to the message to
    # make it happy, but only if we actually have values in those arrays.

    # TODO: We should be pulling the recipients out of the template and shove them into To, Cc and Bcc

    $self->set_header( 'To', join ( ', ', @{ $self->{'To'} } ) )
      if ( ! $MIMEObj->head->get('To') &&  $self->{'To'} && @{ $self->{'To'} } );
    $self->set_header( 'Cc', join ( ', ', @{ $self->{'Cc'} } ) )
      if ( !$MIMEObj->head->get('Cc') && $self->{'Cc'} && @{ $self->{'Cc'} } );
    $self->set_header( 'Bcc', join ( ', ', @{ $self->{'Bcc'} } ) )
      if ( !$MIMEObj->head->get('Bcc') && $self->{'Bcc'} && @{ $self->{'Bcc'} } );

    # PseudoTo	(fake to headers) shouldn't get matched for message recipients.
    # If we don't have any 'To' header (but do have other recipients), drop in
    # the pseudo-to header.
    $self->set_header( 'To', join ( ', ', @{ $self->{'PseudoTo'} } ) )
        if $self->{'PseudoTo'} && @{ $self->{'PseudoTo'} } && !$MIMEObj->head->get('To') 
           && ( $MIMEObj->head->get('Cc') or $MIMEObj->head->get('Bcc') );

    # We should never have to set the MIME-Version header
    $self->set_header( 'MIME-Version', '1.0' );

    # fsck.com #5959: Since RT sends 8bit mail, we should say so.
    $self->set_header( 'Content-Transfer-Encoding','8bit');

    # For security reasons, we only send out textual mails.
    my @parts = $MIMEObj;
    while (my $part = shift @parts) {
        if ($part->is_multipart) {
            push @parts, $part->parts;
        }
        else {
            $part->head->mime_attr( "Content-Type" => 'text/plain' )
                unless RT::I18N::is_textual_content_type($part->mime_type);
            $part->head->mime_attr( "Content-Type.charset" => 'utf-8' );
        }
    }


    RT::I18N::set_mime_entity_to_encoding(
        $MIMEObj,
        RT->Config->Get('EmailOutputEncoding'),
        'mime_words_ok',
    );

    # Build up a MIME::Entity that looks like the original message.
    $self->AddAttachments if $MIMEObj->head->get('RT-Attach-Message');

    $self->AddTickets;

    my $attachment = $self->transaction_obj->Attachments->first;
    if ( $attachment && !( $attachment->get_header('X-RT-Encrypt') || $self->ticket_obj->queue_obj->Encrypt ) ) {
        $attachment->set_header( 'X-RT-Encrypt' => 1 )
            if $attachment->get_header("X-RT-Incoming-Encryption")||'' eq 'Success';
    }

    return $result;
}

=head2 To

Returns an array of L<Mail::Address> objects containing all the To: recipients for this notification

=cut

sub To {
    my $self = shift;
    return ($self->_AddressesFromHeader('To'));
}

=head2 Cc

Returns an array of L<Mail::Address> objects containing all the Cc: recipients for this notification

=cut

sub Cc { 
    my $self = shift;
    return ($self->_AddressesFromHeader('Cc'));
}

=head2 Bcc

Returns an array of L<Mail::Address> objects containing all the Bcc: recipients for this notification

=cut


sub Bcc {
    my $self = shift;
    return ($self->_AddressesFromHeader('Bcc'));

}

sub _AddressesFromHeader  {
    my $self = shift;
    my $field = shift;
    my $header = $self->template_obj->MIMEObj->head->get($field);
    my @addresses = Mail::Address->parse($header);

    return (@addresses);
}


=head2 SendMessage MIMEObj

sends the message using RT's preferred API.
TODO: Break this out to a separate module

=cut

sub SendMessage {
    # DO NOT SHIFT @_ in this subroutine.  It breaks Hook::LexWrap's
    # ability to pass @_ to a 'post' routine.
    my ( $self, $MIMEObj ) = @_;

    my $msgid = $MIMEObj->head->get('Message-ID');
    chomp $msgid;

    $self->ScripActionObj->{_Message_ID}++;
    
    Jifty->log->info( $msgid . " #"
        . $self->ticket_obj->id . "/"
        . $self->transaction_obj->id
        . " - Scrip "
        . $self->scrip_obj->id . " "
        . ($self->scrip_obj->Description || '') );

    my $status = RT::Interface::Email::SendEmail(
        Entity => $MIMEObj,
        Ticket => $self->ticket_obj,
        Transaction => $self->transaction_obj,
    );
    return $status unless $status > 0;

    my $success = $msgid . " sent ";
    foreach( qw(To Cc Bcc) ) {
        my $recipients = $MIMEObj->head->get($_);
        $success .= " $_: ". $recipients if $recipients;
    }
    $success =~ s/\n//g;

    Jifty->log->info($success);

    return (1);
}



=head2 AddAttachments

Takes any attachments to this transaction and attaches them to the message
we're building.

=cut


sub AddAttachments {
    my $self = shift;

    my $MIMEObj = $self->template_obj->MIMEObj;

    $MIMEObj->head->delete('RT-Attach-Message');

    my $attachments = RT::Model::AttachmentCollection->new(current_user => RT->system_user);
    $attachments->limit(
        column => 'TransactionId',
        value => $self->transaction_obj->id
    );
    # Don't attach anything blank
    $attachments->limit_NotEmpty;
    $attachments->order_by( column => 'id');

    # We want to make sure that we don't include the attachment that's
    # being sued as the "Content" of this message"
    my $transaction_content_obj = $self->transaction_obj->ContentObj;
    # XXX: this is legacy check of content type looks quite incorrect
    # to me //ruz
    if ( $transaction_content_obj && $transaction_content_obj->id
         && $transaction_content_obj->ContentType =~ m{text/plain}i )
    {
        $attachments->limit(
            entry_aggregator => 'AND',
            column           => 'id',
            operator        => '!=',
            value           => $transaction_content_obj->id,
        );
    }

    # attach any of this transaction's attachments
    while ( my $attach = $attachments->next ) {
        $MIMEObj->make_multipart('mixed');
        $self->AddAttachment( $attach );
    }

}

=head2 AddAttachment $attachment

Takes one attachment object of L<RT::Model::Attachmment> class and attaches it to the message
we're building.

=cut

sub AddAttachment {
    my $self = shift;
    my $attach = shift;
    my $MIMEObj = shift || $self->template_obj->MIMEObj;

    $MIMEObj->attach(
        Type     => $attach->ContentType,
        Charset  => $attach->original_encoding,
        Data     => $attach->original_content,
        Filename => defined ($attach->Filename) ? 
          $self->MIMEEncodeString( $attach->Filename, RT->Config->Get('EmailOutputEncoding') )
          :
          undef,
        'RT-Attachment:' => $self->ticket_obj->id."/".$self->transaction_obj->id."/".$attach->id,
        Encoding => '-SUGGEST',
    );
}

=head2 AttachTickets [@IDs]

Returns or set list of ticket's IDs that should be attached to an outgoing message.

B<Note> this method works as a class method and setup things global, so you have to
clean list by passing undef as argument.

=cut

{
    my $list = [];
    sub AttachTickets {
        my $self = shift;
        $list = [ grep defined, @_ ] if @_;
        return @$list;
    }
}

=head2 AddTickets

Attaches tickets to the current message, list of tickets' ids get from
L</AttachTickets> method.

=cut

sub AddTickets {
    my $self = shift;
    $self->AddTicket($_) foreach $self->AttachTickets;
    return;
}

=head2 AddTicket $ID

Attaches a ticket with ID to the message.

Each ticket is attached as multipart entity and all its messages and attachments
are attached as sub entities in order of creation, but only if transaction type
is Create or Correspond.

=cut

sub AddTicket {
    my $self = shift;
    my $tid = shift;

    # XXX: we need a current user here, but who is current user?
    my $attachs = RT::Model::AttachmentCollection->new(current_user => RT->system_user );
    my $txn_alias = $attachs->TransactionAlias;
    $attachs->limit( alias => $txn_alias, column => 'Type', value => 'Create' );
    $attachs->limit( alias => $txn_alias, column => 'Type', value => 'Correspond' );
    $attachs->limit_ByTicket( $tid );
    $attachs->limit_NotEmpty;
    $attachs->order_by( column => 'Created' );

    my $ticket_mime = MIME::Entity->build(
        Type => 'multipart/mixed',
        Top => 0,
        Description => "ticket #$tid",
    );
    while ( my $attachment = $attachs->next ) {
        $self->AddAttachment( $attachment, $ticket_mime );
    }
    if ( $ticket_mime->parts ) {
        my $email_mime = $self->template_obj->MIMEObj;
        $email_mime->make_multipart;
        $email_mime->add_part( $ticket_mime );
    }
    return;
}

=head2 RecordOutgoingMailTransaction MIMEObj

Record a transaction in RT with this outgoing message for future record-keeping purposes

=cut



sub RecordOutgoingMailTransaction {
    my $self = shift;
    my $MIMEObj = shift;

    my @parts = $MIMEObj->parts;
    my @attachments;
    my @keep;
    foreach my $part (@parts) {
        my $attach = $part->head->get('RT-Attachment');
        if ($attach) {
            Jifty->log->debug("We found an attachment. we want to not record it.");
            push @attachments, $attach;
        } else {
            Jifty->log->debug("We found a part. we want to record it.");
            push @keep, $part;
        }
    }
    $MIMEObj->parts(\@keep);
    foreach my $attachment (@attachments) {
        $MIMEObj->head->add('RT-Attachment', $attachment);
    }

    RT::I18N::set_mime_entity_to_encoding( $MIMEObj, 'utf-8', 'mime_words_ok' );

    my $transaction = RT::Model::Transaction->new(current_user => $self->transaction_obj->current_user);

    # XXX: TODO -> Record attachments as references to things in the attachments table, maybe.

    my $type;
    if ($self->transaction_obj->Type eq 'comment') {
        $type = 'commentEmailRecord';
    } else {
        $type = 'EmailRecord';
    }

    my $msgid = $MIMEObj->head->get('Message-ID');
    chomp $msgid;

    my ( $id, $msg ) = $transaction->create(
        Ticket         => $self->ticket_obj->id,
        Type           => $type,
        Data           => $msgid,
        MIMEObj        => $MIMEObj,
        ActivateScrips => 0
    );

    if( $id ) {
        $self->{'OutgoingMailTransaction'} = $id;
    } else {
        Jifty->log->warn( "Could not record outgoing message transaction: $msg" );
    }
    return $id;
}

=head2 SetRTSpecialHeaders 

This routine adds all the random headers that RT wants in a mail message
that don't matter much to anybody else.

=cut

sub set_RTSpecialHeaders {
    my $self = shift;

    $self->set_Subject();
    $self->set_SubjectToken();
    $self->set_headerAsEncoding( 'Subject', RT->Config->Get('EmailOutputEncoding') )
      if (RT->Config->Get('EmailOutputEncoding'));
    $self->set_ReturnAddress();
    $self->set_ReferencesHeaders();

    unless ($self->template_obj->MIMEObj->head->get('Message-ID')) {
      # Get Message-ID for this txn
      my $msgid = "";
      if ( my $msg = $self->transaction_obj->Message->first ) {
        $msgid = $msg->get_header("RT-Message-ID")
            || $msg->get_header("Message-ID")
      }

      # If there is one, and we can parse it, then base our Message-ID on it
      if ($msgid 
          and $msgid =~ s/<(rt-.*?-\d+-\d+)\.(\d+)-\d+-\d+\@\QRT->Config->Get('organization')\E>$/
                         "<$1." . $self->ticket_obj->id
                          . "-" . $self->scrip_obj->id
                          . "-" . $self->ScripActionObj->{_Message_ID}
                          . "@" . RT->Config->Get('organization') . ">"/eg
          and $2 == $self->ticket_obj->id) {
        $self->set_header( "Message-ID" => $msgid );
      } else {
        $self->set_header(
            'Message-ID' => RT::Interface::Email::GenMessageId(
                Ticket => $self->ticket_obj,
                Scrip => $self->scrip_obj,
                ScripAction => $self->ScripActionObj
            ),
        );
      }
    }

    $self->set_header( 'Precedence', "bulk" )
      unless ( $self->template_obj->MIMEObj->head->get("Precedence") );

    $self->set_header( 'X-RT-Loop-Prevention', RT->Config->Get('rtname') );
    $self->set_header( 'RT-Ticket',
        RT->Config->Get('rtname') . " #" . $self->ticket_obj->id() );
    $self->set_header( 'Managed-by',
        "RT $RT::VERSION (http://www.bestpractical.com/rt/)" );

    # XXX, TODO: use /ShowUser/ShowUserEntry(or something like that) when it would be 
    #            refactored into user's method.
    if (my $email = $self->transaction_obj->creator_obj->email) {
      $self->set_header( 'RT-Originator', $email );
    }

}

=head2 SquelchMailTo [@ADDRESSES]

Mark ADDRESSES to be removed from list of the recipients. Returns list of the addresses.
To empty list pass undefined argument.

B<Note> that this method can be called as class method and works globaly. Don't forget to
clean this list when blocking is not required anymore, pass undef to do this.

=cut

{
    my $squelch = [];
    sub SquelchMailTo {
        my $self = shift;
        if ( @_ ) {
            $squelch = [ grep defined, @_ ];
        }
        return @$squelch;
    }
}

=head2 RemoveInappropriateRecipients

Remove addresses that are RT addresses or that are on this transaction's blacklist

=cut

sub RemoveInappropriateRecipients {
    my $self = shift;

    my $msgid = $self->template_obj->MIMEObj->head->get  ('Message-Id');



    my @blacklist;

    my @types = qw/To Cc Bcc/;

    # Weed out any RT addresses. We really don't want to talk to ourselves!
    foreach my $type (@types) {
        @{ $self->{$type} } =
          RT::EmailParser::CullRTAddresses( "", @{ $self->{$type} } );
    }

    # If there are no recipients, don't try to send the message.
    # If the transaction has content and has the header RT-Squelch-Replies-To

    if ( my $attachment = $self->transaction_obj->Attachments->first ) {
        if ( $attachment->get_header( 'RT-DetectedAutoGenerated') ) {

            # What do we want to do with this? It's probably (?) a bounce
            # caused by one of the watcher addresses being broken.
            # Default ("true") is to redistribute, for historical reasons.

            if ( !RT->Config->Get('RedistributeAutoGeneratedMessages') ) {

                # Don't send to any watchers.
                @{ $self->{'To'} }  = ();
                @{ $self->{'Cc'} }  = ();
                @{ $self->{'Bcc'} } = ();

                Jifty->log->info( $msgid . " The incoming message was autogenerated. Not redistributing this message based on site configuration.\n");
            }
            elsif ( RT->Config->Get('RedistributeAutoGeneratedMessages') eq 'privileged' ) {

                # Only send to "privileged" watchers.
                #

                foreach my $type (@types) {

                    foreach my $addr ( @{ $self->{$type} } ) {
                        my $user = RT::Model::User->new(current_user => RT->system_user);
                        $user->load_by_email($addr);
                        @{ $self->{$type} } =
                          grep ( !/^\Q$addr\E$/, @{ $self->{$type} } )
                          if ( !$user->privileged );

                    }
                }
                Jifty->log->info( $msgid . " The incoming message was autogenerated. Not redistributing this message to unprivileged users based on site configuration.\n");

            }

        }

        if ( my $squelch = $attachment->get_header('RT-Squelch-Replies-To') ) {
            @blacklist = split( /,/, $squelch );
        }
    }

    # Let's grab the SquelchMailTo attribue and push those entries into the @blacklist
    push @blacklist, map $_->Content, $self->ticket_obj->SquelchMailTo;
    push @blacklist, $self->SquelchMailTo;

    # Cycle through the people we're sending to and pull out anyone on the
    # system blacklist

    foreach my $person_to_yank (@blacklist) {
        $person_to_yank =~ s/\s//g;
        foreach my $type (@types) {
            @{ $self->{$type} } =
              grep !/^\Q$person_to_yank\E$/, @{ $self->{$type} };
        }
    }
}

=head2 SetReturnAddress is_comment => BOOLEAN

Calculate and set From and Reply-To headers based on the is_comment flag.

=cut

sub set_ReturnAddress {

    my $self = shift;
    my %args = (
        is_comment => 0,
        @_
    );

    # From and Reply-To
    # $args{is_comment} should be set if the comment address is to be used.
    my $replyto;

    if ( $args{'is_comment'} ) {
        $replyto = $self->ticket_obj->queue_obj->comment_address
          || RT->Config->Get('comment_address');
    }
    else {
        $replyto = $self->ticket_obj->queue_obj->correspond_address
          || RT->Config->Get('correspond_address');
    }

    unless ( $self->template_obj->MIMEObj->head->get('From') ) {
        if (RT->Config->Get('UseFriendlyFromLine')) {
            my $friendly_name = $self->transaction_obj->creator_obj->friendly_name;
            if ( $friendly_name =~ /^"(.*)"$/ ) {    # a quoted string
                $friendly_name = $1;
            }

            $friendly_name =~ s/"/\\"/g;
            $self->set_header(
                'From',
                sprintf(
                    RT->Config->Get('FriendlyFromLineFormat'),
                    $self->MIMEEncodeString( $friendly_name,
                        RT->Config->Get('EmailOutputEncoding') ),
                    $replyto
                ),
            );
        }
        else {
            $self->set_header( 'From', $replyto );
        }
    }

    unless ( $self->template_obj->MIMEObj->head->get('Reply-To') ) {
        $self->set_header( 'Reply-To', "$replyto" );
    }

}

=head2 SetHeader column, value

Set the column of the current MIME object into value.

=cut

sub set_header {
    my $self  = shift;
    my $field = shift;
    my $val   = shift;

    chomp $val;
    chomp $field;
    $self->template_obj->MIMEObj->head->fold_length( $field, 10000 );
    $self->template_obj->MIMEObj->head->replace( $field,     $val );
    return $self->template_obj->MIMEObj->head->get($field);
}

=head2 SetSubject

This routine sets the subject. it does not add the rt tag. that gets done elsewhere
If $self->{'Subject'} is already defined, it uses that. otherwise, it tries to get
the transaction's subject.

=cut 

sub set_Subject {
    my $self = shift;
    my $subject;

    if ( $self->template_obj->MIMEObj->head->get('Subject') ) {
        return ();
    }

    my $message = $self->transaction_obj->Attachments;
    $message->rows_per_page(1);
    if ( $self->{'Subject'} ) {
        $subject = $self->{'Subject'};
    }
    elsif ( my $first = $message->first ) {
        my $tmp = $first->get_header('Subject');
        $subject = defined $tmp? $tmp: $self->ticket_obj->Subject;
    }
    else {
        $subject = $self->ticket_obj->Subject();
    }

    $subject =~ s/(\r\n|\n|\s)/ /gi;

    chomp $subject;
    $self->set_header( 'Subject', $subject );

}

=head2 SetSubjectToken

This routine fixes the RT tag in the subject. It's unlikely that you want to overwrite this.

=cut

sub set_SubjectToken {
    my $self = shift;

    $self->template_obj->MIMEObj->head->replace(
        Subject => RT::Interface::Email::AddSubjectTag(
            $self->template_obj->MIMEObj->head->get('Subject'),
            $self->ticket_obj->id,
        ),
    );
}

=head2 SetReferencesHeaders

Set References and In-Reply-To headers for this message.

=cut

sub set_ReferencesHeaders {
    my $self = shift;
    my ( @in_reply_to, @references, @msgid );

    if ( my $top = $self->transaction_obj->Message->first ) {
        @in_reply_to = split(/\s+/m, $top->get_header('In-Reply-To') || '');  
        @references = split(/\s+/m, $top->get_header('References') || '' );  
        @msgid = split(/\s+/m, $top->get_header('Message-ID') || ''); 
    }
    else {
        return (undef);
    }

    # There are two main cases -- this transaction was Created with
    # the RT Web UI, and hence we want to *not* append its Message-ID
    # to the References and In-Reply-To.  OR it came from an outside
    # source, and we should treat it as per the RFC
    my $org = RT->Config->Get('organization');
    if ( "@msgid" =~ /<(rt-.*?-\d+-\d+)\.(\d+)-0-0\@\Q$org\E>/) {

      # Make all references which are internal be to version which we
      # have sent out

      for (@references, @in_reply_to) {
        s/<(rt-.*?-\d+-\d+)\.(\d+-0-0)\@\Q$org\E>$/
          "<$1." . $self->ticket_obj->id .
             "-" . $self->scrip_obj->id .
             "-" . $self->ScripActionObj->{_Message_ID} .
             "@" . $org . ">"/eg
      }

      # In reply to whatever the internal message was in reply to
      $self->set_header( 'In-Reply-To', join( " ",  ( @in_reply_to )));

      # Default the references to whatever we're in reply to
      @references = @in_reply_to unless @references;

      # References are unchanged from internal
    } else {
      # In reply to that message
      $self->set_header( 'In-Reply-To', join( " ",  ( @msgid )));

      # Default the references to whatever we're in reply to
      @references = @in_reply_to unless @references;

      # Push that message onto the end of the references
      push @references, @msgid;
    }

    # Push pseudo-ref to the front
    my $pseudo_ref = $self->PseudoReference;
    @references = ($pseudo_ref, grep { $_ ne $pseudo_ref } @references);

    # If there are more than 10 references headers, remove all but the
    # first four and the last six (Gotta keep this from growing
    # forever)
    splice(@references, 4, -6) if ($#references >= 10);

    # Add on the references
    $self->set_header( 'References', join( " ",   @references) );
    $self->template_obj->MIMEObj->head->fold_length( 'References', 80 );

}

=head2 PseudoReference

Returns a fake Message-ID: header for the ticket to allow a base level of threading

=cut

sub PseudoReference {

    my $self = shift;
    my $pseudo_ref =  '<RT-Ticket-'.$self->ticket_obj->id .'@'.RT->Config->Get('organization') .'>';
    return $pseudo_ref;
}


=head2 SetHeaderAsEncoding($field_name, $charset_encoding)

This routine converts the field into specified charset encoding.

=cut

sub set_headerAsEncoding {
    my $self = shift;
    my ( $field, $enc ) = ( shift, shift );

    if ($field eq 'From' and RT->Config->Get('SMTPFrom')) {
        $self->template_obj->MIMEObj->head->replace( $field, RT->Config->Get('SMTPFrom') );
	return;
    }

    my $value = $self->template_obj->MIMEObj->head->get($field);

    $value =  $self->MIMEEncodeString($value, $enc);

    $self->template_obj->MIMEObj->head->replace( $field, $value );


} 

=head2 MIMEEncodeString STRING ENCODING

Takes a string and a possible encoding and returns the string wrapped in MIME goo.

=cut

sub MIMEEncodeString {
    my  $self = shift;
    my $value = shift;
    # using RFC2047 notation, sec 2.
    # encoded-word = "=?" charset "?" encoding "?" encoded-text "?="
    my $charset = shift;
    my $encoding = 'B';
    # An 'encoded-word' may not be more than 75 characters long
    #
    # MIME encoding increases 4/3*(number of bytes), and always in multiples
    # of 4. Thus we have to find the best available value of bytes available
    # for each chunk.
    #
    # First we get the integer max which max*4/3 would fit on space.
    # Then we find the greater multiple of 3 lower or equal than $max.
    my $max = int(((75-length('=?'.$charset.'?'.$encoding.'?'.'?='))*3)/4);
    $max = int($max/3)*3;

    chomp $value;

    if ( $max <= 0 ) {
      # gives an error...
      Jifty->log->fatal("Can't encode! Charset or encoding too big.\n");
      return ($value);
    }

    return ($value) unless $value =~ /[^\x20-\x7e]/;

    $value =~ s/\s*$//;

    # we need perl string to split thing char by char
    Encode::_utf8_on($value) unless Encode::is_utf8( $value );

    my ($tmp, @chunks) = ('', ());
    while ( length $value ) {
        my $char = substr($value, 0, 1, '');
        my $octets = Encode::encode( $charset, $char );
        if ( length($tmp) + length($octets) > $max ) {
            push @chunks, $tmp;
            $tmp = '';
        }
        $tmp .= $octets;
    }
    push @chunks, $tmp if length $tmp;

    # encode an join chuncks
    $value = join "\n ",
               map encode_mimeword( $_, $encoding, $charset ), @chunks ;
    return($value); 
}

1;
