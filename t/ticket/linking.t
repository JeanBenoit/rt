use RT::Test; use Test::More  tests => '89';

use strict;
use warnings;

use_ok('RT');
use_ok('RT::Model::Ticket');
use_ok('RT::Model::ScripConditionCollection');
use_ok('RT::Model::ScripActionCollection');
use_ok('RT::Model::Template');
use_ok('RT::Model::ScripCollection');
use_ok('RT::Model::Scrip');



use File::Temp qw/tempfile/;
my ($fh, $filename) = tempfile( UNLINK => 1, SUFFIX => '.rt');
my $link_scrips_orig = RT->Config->Get( 'LinkTransactionsRun1Scrip' );
RT->Config->set( 'LinkTransactionsRun1Scrip', 1 );

my $link_acl_checks_orig = RT->Config->Get( 'StrictLinkACL' );
RT->Config->set( 'StrictLinkACL', 1);

my $condition = RT::Model::ScripCondition->new( RT->system_user );
$condition->load('User Defined');
ok($condition->id);
my $action = RT::Model::ScripAction->new( RT->system_user );
$action->load('User Defined');
ok($action->id);
my $template = RT::Model::Template->new( RT->system_user );
$template->load('Blank');
ok($template->id);

my $q1 = RT::Model::Queue->new(RT->system_user);
my ($id,$msg) = $q1->create(Name => "LinkTest1.$$");
ok ($id,$msg);
my $q2 = RT::Model::Queue->new(RT->system_user);
($id,$msg) = $q2->create(Name => "LinkTest2.$$");
ok ($id,$msg);

my $commit_code = <<END;
	open my \$file, "<$filename" or die "couldn't open $filename";
	my \$data = <\$file>;
	chomp \$data;
	\$data += 0;
	close \$file;
	\$RT::Logger->debug("Data is \$data");
	
	open \$file, ">$filename" or die "couldn't open $filename";
	if (\$self->TransactionObj->Type eq 'AddLink') {
	    \$RT::Logger->debug("AddLink");
	    print \$file \$data+1, "\n";
	}
	elsif (\$self->TransactionObj->Type eq 'DeleteLink') {
	    \$RT::Logger->debug("delete_link");
	    print \$file \$data-1, "\n";
	}
	else {
	    \$RT::Logger->error("THIS SHOULDN'T HAPPEN");
	    print \$file "666\n";
	}
	close \$file;
	1;
END

my $Scrips = RT::Model::ScripCollection->new( RT->system_user );
$Scrips->find_all_rows;
while ( my $Scrip = $Scrips->next ) {
    $Scrip->delete if $Scrip->Description and $Scrip->Description =~ /Add or Delete Link \d+/;
}


my $scrip = RT::Model::Scrip->new(RT->system_user);
($id,$msg) = $scrip->create( Description => "Add or Delete Link $$",
                          ScripCondition => $condition->id,
                          ScripAction    => $action->id,
                          Template       => $template->id,
                          Stage          => 'TransactionCreate',
                          Queue          => 0,
                  CustomIsApplicableCode => '$self->TransactionObj->Type =~ /(Add|Delete)Link/;',
                       CustomPrepareCode => '1;',
                       CustomCommitCode  => $commit_code,
                           );
ok($id, "Scrip Created");

my $u1 = RT::Model::User->new(RT->system_user);
($id,$msg) = $u1->create(Name => "LinkTestUser.$$");
ok ($id,$msg);

# grant ShowTicket right to allow count transactions
($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q1, Right => 'ShowTicket');
ok ($id,$msg);
($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q2, Right => 'ShowTicket');
ok ($id,$msg);
($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q1, Right => 'CreateTicket');
ok ($id,$msg);

my $creator = RT::CurrentUser->new($u1->id);

diag('Create tickets without rights to link') if $ENV{'TEST_VERBOSE'};
{
    # on q2 we have no rights, yet
    my $parent = RT::Model::Ticket->new( RT->system_user );
    my ($id,$tid,$msg) = $parent->create( Subject => 'Link test 1', Queue => $q2->id );
    ok($id,$msg);
    my $child = RT::Model::Ticket->new( $creator );
    ($id,$tid,$msg) = $child->create( Subject => 'Link test 1', Queue => $q1->id, MemberOf => $parent->id );
    ok($id,$msg);
    $child->current_user( RT->system_user );
    is($child->_Links('Base')->count, 0, 'link was not Created, no permissions');
    is($child->_Links('Target')->count, 0, 'link was not create, no permissions');
}

diag('Create tickets with rights checks on one end of a link') if $ENV{'TEST_VERBOSE'};
{
    # on q2 we have no rights, but use checking one only on thing
    RT->Config->set( StrictLinkACL => 0 );
    my $parent = RT::Model::Ticket->new( RT->system_user );
    my ($id,$tid,$msg) = $parent->create( Subject => 'Link test 1', Queue => $q2->id );
    ok($id,$msg);
    my $child = RT::Model::Ticket->new( $creator );
    ($id,$tid,$msg) = $child->create( Subject => 'Link test 1', Queue => $q1->id, MemberOf => $parent->id );
    ok($id,$msg);
    $child->current_user( RT->system_user );
    is($child->_Links('Base')->count, 1, 'link was Created');
    is($child->_Links('Target')->count, 0, 'link was Created only one');
    # no scrip run on second ticket accroding to config option
    is(link_count($filename), undef, "scrips ok");
    RT->Config->set( StrictLinkACL => 1 );
}

($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q1, Right => 'ModifyTicket');
ok ($id,$msg);

diag('try to add link without rights') if $ENV{'TEST_VERBOSE'};
{
    # on q2 we have no rights, yet
    my $parent = RT::Model::Ticket->new( RT->system_user );
    my ($id,$tid,$msg) = $parent->create( Subject => 'Link test 1', Queue => $q2->id );
    ok($id,$msg);
    my $child = RT::Model::Ticket->new( $creator );
    ($id,$tid,$msg) = $child->create( Subject => 'Link test 1', Queue => $q1->id );
    ok($id,$msg);
    ($id, $msg) = $child->AddLink(Type => 'MemberOf', Target => $parent->id);
    ok(!$id, $msg);
    is(link_count($filename), undef, "scrips ok");
    $child->current_user( RT->system_user );
    is($child->_Links('Base')->count, 0, 'link was not Created, no permissions');
    is($child->_Links('Target')->count, 0, 'link was not create, no permissions');
}

diag('add link with rights only on base') if $ENV{'TEST_VERBOSE'};
{
    # on q2 we have no rights, but use checking one only on thing
    RT->Config->set( StrictLinkACL => 0 );
    my $parent = RT::Model::Ticket->new( RT->system_user );
    my ($id,$tid,$msg) = $parent->create( Subject => 'Link test 1', Queue => $q2->id );
    ok($id,$msg);
    my $child = RT::Model::Ticket->new( $creator );
    ($id,$tid,$msg) = $child->create( Subject => 'Link test 1', Queue => $q1->id );
    ok($id,$msg);
    ($id, $msg) = $child->AddLink(Type => 'MemberOf', Target => $parent->id);
    ok($id, $msg);
    is(link_count($filename), 1, "scrips ok");
    $child->current_user( RT->system_user );
    is($child->_Links('Base')->count, 1, 'link was Created');
    is($child->_Links('Target')->count, 0, 'link was Created only one');
    $child->current_user( $creator );

    # turn off feature and try to delete link, we should fail
    RT->Config->set( StrictLinkACL => 1 );
    ($id, $msg) = $child->AddLink(Type => 'MemberOf', Target => $parent->id);
    ok(!$id, $msg);
    is(link_count($filename), 1, "scrips ok");
    $child->current_user( RT->system_user );
    $child->_Links('Base')->_do_count;
    is($child->_Links('Base')->count, 1, 'link was not deleted');
    $child->current_user( $creator );

    # try to delete link, we should success as feature is active
    RT->Config->set( StrictLinkACL => 0 );
    ($id, $msg) = $child->delete_link(Type => 'MemberOf', Target => $parent->id);
    ok($id, $msg);
    is(link_count($filename), 0, "scrips ok");
    $child->current_user( RT->system_user );
    $child->_Links('Base')->_do_count;
    is($child->_Links('Base')->count, 0, 'link was deleted');
    RT->Config->set( StrictLinkACL => 1 );
}

my $tid;
my $ticket = RT::Model::Ticket->new( $creator);
ok($ticket->isa('RT::Model::Ticket'));
($id,$tid, $msg) = $ticket->create(Subject => 'Link test 1', Queue => $q1->id);
ok ($id,$msg);

diag('try link to itself') if $ENV{'TEST_VERBOSE'};
{
    my ($id, $msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket->id);
    ok(!$id, $msg);
    is(link_count($filename), 0, "scrips ok");
}

my $ticket2 = RT::Model::Ticket->new(RT->system_user);
($id, $tid, $msg) = $ticket2->create(Subject => 'Link test 2', Queue => $q2->id);
ok ($id, $msg);
($id,$msg) =$ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id);
ok(!$id,$msg);
is(link_count($filename), 0, "scrips ok");

($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q2, Right => 'CreateTicket');
ok ($id,$msg);
($id,$msg) = $u1->PrincipalObj->GrantRight ( Object => $q2, Right => 'ModifyTicket');
ok ($id,$msg);
($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id);
ok($id,$msg);
is(link_count($filename), 1, "scrips ok");
($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => -1);
ok(!$id,$msg);
($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id);
ok($id,$msg);
is(link_count($filename), 1, "scrips ok");

my $transactions = $ticket2->Transactions;
$transactions->limit( column => 'Type', value => 'AddLink' );
is( $transactions->count, 1, "Transaction found in other ticket" );
is( $transactions->first->Field , 'ReferredToBy');
is( $transactions->first->NewValue , $ticket->URI );

($id,$msg) = $ticket->delete_link(Type => 'RefersTo', Target => $ticket2->id);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");
$transactions = $ticket2->Transactions;
$transactions->limit( column => 'Type', value => 'DeleteLink' );
is( $transactions->count, 1, "Transaction found in other ticket" );
is( $transactions->first->Field , 'ReferredToBy');
is( $transactions->first->OldValue , $ticket->URI );

RT->Config->set( LinkTransactionsRun1Scrip => 0 );

($id,$msg) =$ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id);
ok($id,$msg);
is(link_count($filename), 2, "scrips ok");
($id,$msg) =$ticket->delete_link(Type => 'RefersTo', Target => $ticket2->id);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");

# tests for silent behaviour
($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id, Silent => 1);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");
{
    my $transactions = $ticket->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 2, "Still two txns on the base" );

    $transactions = $ticket2->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 2, "Still two txns on the target" );

}
($id,$msg) =$ticket->delete_link(Type => 'RefersTo', Target => $ticket2->id, Silent => 1);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");

($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id, SilentBase => 1);
ok($id,$msg);
is(link_count($filename), 1, "scrips ok");
{
    my $transactions = $ticket->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 2, "still five txn on the base" );

    $transactions = $ticket2->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 3, "+1 txn on the target" );

}
($id,$msg) =$ticket->delete_link(Type => 'RefersTo', Target => $ticket2->id, SilentBase => 1);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");

($id,$msg) = $ticket->AddLink(Type => 'RefersTo', Target => $ticket2->id, SilentTarget => 1);
ok($id,$msg);
is(link_count($filename), 1, "scrips ok");
{
    my $transactions = $ticket->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 3, "+1 txn on the base" );

    $transactions = $ticket2->Transactions;
    $transactions->limit( column => 'Type', value => 'AddLink' );
    is( $transactions->count, 3, "three txns on the target" );
}
($id,$msg) =$ticket->delete_link(Type => 'RefersTo', Target => $ticket2->id, SilentTarget => 1);
ok($id,$msg);
is(link_count($filename), 0, "scrips ok");


# restore
RT->Config->set( LinkTransactionsRun1Scrip => $link_scrips_orig );
RT->Config->set( StrictLinkACL => $link_acl_checks_orig );

{
    my $Scrips = RT::Model::ScripCollection->new( RT->system_user );
    $Scrips->limit( column => 'Description', operator => 'STARTSWITH', value => 'Add or Delete Link ');
    while ( my $s = $Scrips->next ) { $s->delete };
}


sub link_count {
    my $file = shift;
    open my $fh, "<$file" or die "couldn't open $file";
    my $data = <$fh>;
    close $fh;

    return undef unless $data;
    chomp $data;
    return $data + 0;
}