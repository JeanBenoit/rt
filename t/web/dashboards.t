#!/usr/bin/perl -w
use strict;

use Test::More tests => 59;
use RT::Test;
my ($baseurl, $m) = RT::Test->started_ok;

my $url = $m->rt_base_url;

my $user_obj = RT::User->new($RT::SystemUser);
my ($ret, $msg) = $user_obj->LoadOrCreateByEmail('customer@example.com');
ok($ret, 'ACL test user creation');
$user_obj->SetName('customer');
$user_obj->SetPrivileged(1);
($ret, $msg) = $user_obj->SetPassword('customer');
$user_obj->PrincipalObj->GrantRight(Right => 'ModifySelf');
my $currentuser = RT::CurrentUser->new($user_obj);

my $queue = RT::Queue->new($RT::SystemUser);
$queue->Create(Name => 'SearchQueue'.$$);
$user_obj->PrincipalObj->GrantRight(Right => 'SeeQueue',   Object => $queue);
$user_obj->PrincipalObj->GrantRight(Right => 'ShowTicket', Object => $queue);
$user_obj->PrincipalObj->GrantRight(Right => 'OwnTicket',  Object => $queue);

ok $m->login(customer => 'customer'), "logged in";

$m->get_ok($url."Dashboards/index.html");
$m->content_lacks("New dashboard", "No 'new dashboard' link because we have no ModifyDashboard");

$m->get_ok($url."Dashboards/Modify.html?Create=1");
$m->form_name('ModifyDashboard');
$m->field("Name" => 'test dashboard');
$m->click_button(value => 'Save Changes');
$m->content_contains("No permission to create dashboards");

$user_obj->PrincipalObj->GrantRight(Right => 'ModifyDashboard');

$m->get_ok($url."Dashboards/index.html");
$m->content_contains("New dashboard", "'New dashboard' link because we now have ModifyDashboard");

$m->follow_link_ok({text => "New dashboard"});
$m->form_name('ModifyDashboard');
$m->field("Name" => 'different dashboard');
$m->click_button(value => 'Save Changes');
$m->content_lacks("No permission to create dashboards");
$m->content_contains("Saved dashboard different dashboard");

$m->get_ok($url."Dashboards/index.html");
$m->content_contains("different dashboard");

$m->follow_link_ok({text => "different dashboard"});
$m->content_contains("Basics");
$m->content_contains("Queries");
$m->content_lacks("Subscription", "we don't have the SubscribeDashboard right");
$m->content_contains("Preview");

$m->follow_link_ok({text => "Basics"});
$m->content_contains("Modify the dashboard different dashboard");

$m->follow_link_ok({text => "Queries"});
$m->content_contains("Modify the queries of dashboard different dashboard");
$m->form_name('DashboardQueries');
$m->field('Searches-Available' => ["2-RT::System"]);
$m->click_button(name => 'add');
$m->content_contains("Dashboard updated");

my $dashboard = RT::Dashboard->new($currentuser);
my ($id) = $m->content =~ /name="id" value="(\d+)"/;
ok($id, "got an ID, $id");
$dashboard->LoadById($id);
is($dashboard->Name, "different dashboard");

my @searches = $dashboard->Searches;
is(@searches, 1, "one saved search in the dashboard");
like($searches[0]->Name, qr/newest unowned tickets/, "correct search name");

$m->form_name('DashboardQueries');
$m->field('Searches-Available' => ["1-RT::System"]);
$m->click_button(name => 'add');
$m->content_contains("Dashboard updated");

RT::Record->FlushCache if RT::Record->can('FlushCache');
$dashboard = RT::Dashboard->new($currentuser);
$dashboard->LoadById($id);

@searches = $dashboard->Searches;
is(@searches, 2, "two saved searches in the dashboard");
like($searches[0]->Name, qr/newest unowned tickets/, "correct existing search name");
like($searches[1]->Name, qr/highest priority tickets I own/, "correct new search name");

my $ticket = RT::Ticket->new($RT::SystemUser);
$ticket->Create(
    Queue     => $queue->Id,
	Requestor => [ $user_obj->Name ],
	Owner     => $user_obj,
	Subject   => 'dashboard test',
);

$m->follow_link_ok({text => "Preview"});
$m->content_contains("20 highest priority tickets I own");
$m->content_contains("20 newest unowned tickets");
$m->content_lacks("Bookmarked Tickets");
$m->content_contains("dashboard test", "ticket subject");

$m->get_ok("/Dashboards/$id/This fragment left intentionally blank");
$m->content_contains("20 highest priority tickets I own");
$m->content_contains("20 newest unowned tickets");
$m->content_lacks("Bookmarked Tickets");
$m->content_contains("dashboard test", "ticket subject");

$m->get_ok("/Dashboards/Subscription.html?DashboardId=$id");
$m->form_name('SubscribeDashboard');
$m->click_button(name => 'Save');
$m->content_contains("No permission to subscribe to dashboards");

RT::Record->FlushCache if RT::Record->can('FlushCache');
is($user_obj->Attributes->Named('Subscription'), 0, "no subscriptions");

$user_obj->PrincipalObj->GrantRight(Right => 'SubscribeDashboard');

$m->get_ok("/Dashboards/Modify.html?id=$id");
$m->follow_link_ok({text => "Subscription"});
$m->content_contains("Subscribe to dashboard different dashboard");
$m->content_contains("Unowned Tickets");
$m->content_contains("My Tickets");
$m->content_lacks("Bookmarked Tickets", "only dashboard queries show up");

$m->form_name('SubscribeDashboard');
$m->click_button(name => 'Save');
$m->content_lacks("No permission to subscribe to dashboards");
$m->content_contains("Subscribed to dashboard different dashboard");

RT::Record->FlushCache if RT::Record->can('FlushCache');
TODO: {
    local $TODO = "some kind of caching is still happening (it works if I remove the check above)";
    is($user_obj->Attributes->Named('Subscription'), 1, "we have a subscription");
};

$m->get_ok("/Dashboards/Modify.html?id=$id");
$m->follow_link_ok({text => "Subscription"});
$m->content_contains("Modify the subscription to dashboard different dashboard");

$m->form_name('SubscribeDashboard');
$m->click_button(name => 'Unsubscribe');

$m->content_contains("Unsubscribed to dashboard different dashboard");

RT::Record->FlushCache if RT::Record->can('FlushCache');
is($user_obj->Attributes->Named('Subscription'), 0, "no more subscriptions");