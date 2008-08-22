#!/usr/bin/perl -w
use strict;

use Test::More tests => 36;
use RT::Test;
my ($baseurl, $m) = RT::Test->started_ok;

my $url = $m->rt_base_url;

# create user and queue {{{
my $user_obj = RT::Model::User->new(current_user => RT->system_user);
my ($ok, $msg) = $user_obj->load_or_create_by_email('customer@example.com');
ok($ok, 'ACL test user creation');
$user_obj->set_name('customer');
$user_obj->set_privileged(1);
($ok, $msg) = $user_obj->set_password('customer');
$user_obj->principal_object->grant_right(Right => 'ModifySelf');
my $currentuser = RT::CurrentUser->new($user_obj);

my $queue = RT::Model::Queue->new(current_user => RT->system_user);
$queue->create(Name => 'SearchQueue'.$$);

$user_obj->principal_object->grant_right(Right => $_, Object => $queue)
    for qw/SeeQueue ShowTicket OwnTicket/;

# grant the user all these rights so we can make sure that the group rights
# are checked and not these as well
$user_obj->principal_object->grant_right(Right => $_, Object => $RT::System)
    for qw/SubscribeDashboard CreateOwnDashboard SeeOwnDashboard ModifyOwnDashboard DeleteOwnDashboard/;
# }}}
# create and test groups (outer < inner < user) {{{
my $inner_group = RT::Model::Group->new(current_user => RT->system_user);
($ok, $msg) = $inner_group->create_user_defined_group(Name => "inner", description =>  "inner group");
ok($ok, "created inner group: $msg");

my $outer_group = RT::Model::Group->new(current_user => RT->system_user);
($ok, $msg) = $outer_group->create_user_defined_group(Name => "outer", description =>  "outer group");
ok($ok, "created outer group: $msg");

($ok, $msg) = $outer_group->add_member($inner_group->principal_id);
ok($ok, "added inner as a member of outer: $msg");

($ok, $msg) = $inner_group->add_member($user_obj->principal_id);
ok($ok, "added user as a member of member: $msg");

ok($outer_group->has_member($inner_group->principal_id), "outer has inner");
ok(!$outer_group->has_member($user_obj->principal_id), "outer doesn't have user directly");
ok($outer_group->has_member_recursively($inner_group->principal_id), "outer has inner recursively");
ok($outer_group->has_member_recursively($user_obj->principal_id), "outer has user recursively");

ok(!$inner_group->has_member($outer_group->principal_id), "inner doesn't have outer");
ok($inner_group->has_member($user_obj->principal_id), "inner has user");
ok(!$inner_group->has_member_recursively($outer_group->principal_id), "inner doesn't have outer, even recursively");
ok($inner_group->has_member_recursively($user_obj->principal_id), "inner has user recursively");
# }}}

ok $m->login(customer => 'customer'), "logged in";

$m->get_ok("$url/Dashboards");

$m->follow_link_ok({text => "New dashboard"});
$m->form_name('modify_dashboard');
is_deeply([$m->current_form->find_input('Privacy')->possible_values], ["RT::Model::User-" . $user_obj->Id], "the only selectable privacy is user");
$m->content_lacks('Delete', "Delete button hidden because we are creating");

$user_obj->principal_object->grant_right(Right => 'CreateGroupDashboard', Object => $inner_group);

$m->follow_link_ok({text => "New dashboard"});
$m->form_name('modify_dashboard');
is_deeply([$m->current_form->find_input('Privacy')->possible_values], ["RT::Model::User-" . $user_obj->Id, "RT::Group-" . $inner_group->Id], "the only selectable privacies are user and inner group (not outer group)");
$m->field("Name" => 'inner dashboard');
$m->field("Privacy" => "RT::Group-" . $inner_group->Id);
$m->content_lacks('Delete', "Delete button hidden because we are creating");

$m->click_button(value => 'Save Changes');
$m->content_lacks("No permission to create dashboards");
$m->content_contains("Saved dashboard inner dashboard");
$m->content_lacks('Delete', "Delete button hidden because we lack DeleteDashboard");

my $dashboard = RT::Dashboard->new($currentuser);
my ($id) = $m->content =~ /name="id" value="(\d+)"/;
ok($id, "got an ID, $id");
$dashboard->LoadById($id);
is($dashboard->Name, "inner dashboard");

is($dashboard->Privacy, 'RT::Group-' . $inner_group->Id, "correct privacy");
is($dashboard->PossibleHiddenSearches, 0, "all searches are visible");

$m->get_ok("/Dashboards/Modify.html?id=$id");
$m->content_lacks("inner dashboard", "no SeeGroupDashboard right");
$m->content_contains("Permission denied");

$user_obj->principal_object->grant_right(Right => 'SeeGroupDashboard', Object => $inner_group);
$m->get_ok("/Dashboards/Modify.html?id=$id");
$m->content_contains("inner dashboard", "we now have SeeGroupDashboard right");
$m->content_lacks("Permission denied");

$m->content_contains('Subscription', "Subscription link not hidden because we have SubscribeDashboard");

