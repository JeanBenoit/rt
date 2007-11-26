#!/usr/bin/perl
use strict;
use warnings;

use RT::Test; use Test::More tests => 176;


use Digest::MD5 qw(md5_hex);

use File::Temp qw(tempdir);
my $homedir = tempdir( CLEANUP => 1 );

RT->Config->set( LogToScreen => 'debug' );
RT->Config->set( 'GnuPG',
                 Enable => 1,
                 OutgoingMessagesFormat => 'RFC' );

RT->Config->set( 'GnuPGOptions',
                 homedir => $homedir,
                 passphrase => 'rt-test',
                 'no-permission-warning' => undef);

RT->Config->set( 'MailPlugins' => 'Auth::MailFrom', 'Auth::GnuPG' );

RT::Test->import_gnupg_key('rt-recipient@example.com');
RT::Test->import_gnupg_key('rt-test@example.com', 'public');

my ($baseurl, $m) = RT::Test->started_ok;
ok $m->login, 'we did log in';
$m->get_ok( '/Admin/Queues/');
$m->follow_link_ok( {text => 'General'} );
$m->submit_form( form_number => 3,
         fields      => { CorrespondAddress => 'rt-recipient@example.com' } );
$m->content_like(qr/rt-recipient\@example.com.* - never/, 'has key info.');

diag "load Everyone group" if $ENV{'TEST_VERBOSE'};
my $everyone;
{
    $everyone = RT::Model::Group->new( RT->system_user );
    $everyone->load_system_internal_group('Everyone');
    ok $everyone->id, "loaded 'everyone' group";
}

RT::Test->set_rights(
    Principal => $everyone->PrincipalObj,
    Right => ['CreateTicket'],
);


my $eid = 0;
for my $usage (qw/signed encrypted signed&encrypted/) {
    for my $format (qw/MIME inline/) {
        for my $attachment (qw/plain text-attachment binary-attachment/) {
            ++$eid;
            diag "Email $eid: $usage, $attachment email with $format format" if $ENV{TEST_VERBOSE};
            eval { email_ok($eid, $usage, $format, $attachment) };
        }
    }
}

sub get_contents {
    my $eid = shift;

    my ($file) = glob("t/data/mails/gnupg-basic-set/$eid-*");
    defined $file
        or do { diag "Unable to find t/data/mails/gnupg-basic-set/$eid-*"; return };

    open my $mailhandle, '<', $file
        or do { diag "Unable to read $file: $!"; return };

    my $mail = do { local $/; <$mailhandle> };
    close $mailhandle;

    return $mail;
}

sub email_ok {
    my ($eid, $usage, $format, $attachment) = @_;
    diag "email_ok $eid: $usage, $format, $attachment" if $ENV{'TEST_VERBOSE'};

    my $mail = get_contents($eid)
        or return 0;

    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "$eid: The mail gateway exited normally");
    ok ($id, "$eid: got id of a newly created ticket - $id");

    my $tick = RT::Model::Ticket->new( RT->system_user );
    $tick->load( $id );
    ok ($tick->id, "$eid: loaded ticket #$id");

    is ($tick->Subject,
        "Test Email ID:$eid",
        "$eid: Created the ticket"
    );

    my $txn = $tick->Transactions->first;
    my ($msg, @attachments) = @{$txn->Attachments->items_array_ref};

    if ($usage =~ /encrypted/) {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Success',
            "$eid: recorded incoming mail that is encrypted"
        );
        is( $msg->GetHeader('X-RT-Privacy'),
            'PGP',
            "$eid: recorded incoming mail that is encrypted"
        );

        like( $attachments[0]->Content, qr/ID:$eid/,
                "$eid: incoming mail did NOT have original body"
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Not encrypted',
            "$eid: recorded incoming mail that is not encrypted"
        );
        like( $msg->Content || $attachments[0]->Content, qr/ID:$eid/,
              "$eid: got original content"
        );
    }

    if ($usage =~ /signed/) {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            'RT Test <rt-test@example.com>',
            "$eid: recorded incoming mail that is signed"
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            undef,
            "$eid: recorded incoming mail that is not signed"
        );
    }

    if ($attachment =~ /attachment/) {
        # signed messages should sign each attachment too
        if ($usage =~ /signed/) {
            my $sig = pop @attachments;
            ok ($sig->Id, "$eid: loaded attachment.sig object");
            my $acontent = $sig->Content;
        }

        my ($a) = grep $_->Filename, @attachments;
        ok ($a && $a->Id, "$eid: found attachment with filename");

        my $acontent = $a->Content;
        if ($attachment =~ /binary/)
        {
            is(md5_hex($acontent), '1e35f1aa90c98ca2bab85c26ae3e1ba7', "$eid: The binary attachment's md5sum matches");
        }
        else
        {
            like($acontent, qr/zanzibar/, "$eid: The attachment isn't screwed up in the database.");
        }

    }

    return 0;
}
