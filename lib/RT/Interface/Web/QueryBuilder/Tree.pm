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

package RT::Interface::Web::QueryBuilder::Tree;

use strict;
use warnings;

use Tree::Simple qw/use_weak_refs/;
use base qw/Tree::Simple/;

=head1 NAME

  RT::Interface::Web::QueryBuilder::Tree - subclass of Tree::Simple used in Query Builder

=head1 DESCRIPTION

This class provides support functionality for the Query Builder (Search/Build.html).
It is a subclass of L<Tree::Simple>.

=head1 METHODS

=head2 TraversePrePost PREFUNC POSTFUNC

Traverses the tree depth-first.  Before processing the node's children,
calls PREFUNC with the node as its argument; after processing all of the
children, calls POSTFUNC with the node as its argument.

(Note that unlike Tree::Simple's C<traverse>, it actually calls its functions
on the root node passed to it.)

=cut

sub TraversePrePost {
   my ($self, $prefunc, $postfunc) = @_;

   # XXX: if pre or post action changes siblings (delete or adds)
   # we could have problems
   $prefunc->($self) if $prefunc;

   foreach my $child ($self->getAllChildren()) { 
           $child->TraversePrePost($prefunc, $postfunc);
   }
   
   $postfunc->($self) if $postfunc;
}

=head2 GetReferencedQueues

Returns a hash reference with keys each queue name referenced in a clause in
the key (even if it's "Queue != 'Foo'"), and values all 1.

=cut

sub GetReferencedQueues {
    my $self = shift;

    my $queues = {};

    $self->traverse(
        sub {
            my $node = shift;

            return if $node->isRoot;
            return unless $node->isLeaf;

            my $clause = $node->getNodeValue();

            if ( $clause->{Key} eq 'Queue' ) {
                $queues->{ $clause->{Value} } = 1;
            };
        }
    );

    return $queues;
}

=head2 GetQueryAndOptionList SELECTED_NODES

Given an array reference of tree nodes that have been selected by the user,
traverses the tree and returns the equivalent SQL query and a list of hashes
representing the "clauses" select option list.  Each has contains the keys
TEXT, INDEX, SELECTED, and DEPTH.  TEXT is the displayed text of the option
(including parentheses, not including indentation); INDEX is the 0-based
index of the option in the list (also used as its CGI parameter); SELECTED
is either 'SELECTED' or '', depending on whether the node corresponding
to the select option was in the SELECTED_NODES list; and DEPTH is the
level of indentation for the option.

=cut 

sub GetQueryAndOptionList {
    my $self           = shift;
    my $selected_nodes = shift;

    my $list = $self->__LinearizeTree;
    foreach my $e( @$list ) {
        $e->{'DEPTH'}    = $e->{'NODE'}->getDepth;
        $e->{'SELECTED'} = (grep $_ == $e->{'NODE'}, @$selected_nodes)? qq[ selected="selected"] : '';
    }

    return (join ' ', map $_->{'TEXT'}, @$list), $list;
}

=head2 PruneChildLessAggregators

If tree manipulation has left it in a state where there are ANDs, ORs,
or parenthesizations with no children, get rid of them.

=cut

sub PruneChildlessAggregators {
    my $self = shift;

    $self->TraversePrePost(
        undef,
        sub {
            my $node = shift;
            return unless $node->isLeaf;

            # We're only looking for aggregators (AND/OR)
            return if ref $node->getNodeValue;

            return if $node->isRoot;

            # OK, this is a childless aggregator.  Remove self.
            $node->getParent->removeChild($node);
            $node->DESTROY;
        }
    );
}

=head2 GetDisplayedNodes

This function returns a list of the nodes of the tree in depth-first
order which correspond to options in the "clauses" multi-select box.
In fact, it's all of them but the root and its child.

=cut

sub GetDisplayedNodes {
    return map $_->{NODE}, @{ (shift)->__LinearizeTree };
}


sub __LinearizeTree {
    my $self = shift;

    my ($list, $i) = ([], 0);

    $self->TraversePrePost( sub {
        my $node = shift;
        return if $node->isRoot;

        my $str = '';
        if( $node->getIndex > 0 ) {
            $str .= " ". $node->getParent->getNodeValue ." ";
        }

        unless( $node->isLeaf ) {
            $str .= '( ';
        } else {

            my $clause = $node->getNodeValue;
            $str .= $clause->{Key};
            $str .= " ". $clause->{Op};
            $str .= " ". $clause->{Value};

        }
        $str =~ s/^\s+|\s+$//;

        push @$list, {
            NODE     => $node,
            TEXT     => $str,
            INDEX    => $i,
        };

        $i++;
    }, sub {
        my $node = shift;
        return if $node->isRoot;
        return if $node->isLeaf;
        $list->[-1]->{'TEXT'} .= ' )';
    });

    return $list;
}

sub ParseSQL {
    my $self = shift;
    my %args = (
        Query => '',
        CurrentUser => '', #XXX: Hack
        @_
    );
    my $string = $args{'Query'};

    my @results;

    my %field = %{ RT::Tickets->new( $args{'CurrentUser'} )->FIELDS };
    my %lcfield = map { ( lc($_) => $_ ) } keys %field;

    my $node =  $self;

    my %callback;
    $callback{'OpenParen'} = sub {
        $node = __PACKAGE__->new( 'AND', $node );
    };
    $callback{'CloseParen'} = sub { $node = $node->getParent };
    $callback{'EntryAggregator'} = sub { $node->setNodeValue( $_[0] ) };
    $callback{'Condition'} = sub {
        my ($key, $op, $value) = @_;

        my ($main_key) = split /[.]/, $key;

        my $class;
        if ( exists $lcfield{ lc $main_key } ) {
            $class = $field{ $main_key }->[0];
            $key =~ s/^[^.]+/ $lcfield{ lc $main_key } /e;
        }
        unless( $class ) {
            push @results, [ $args{'CurrentUser'}->loc("Unknown field: [_1]", $key), -1 ]
        }

        $value =~ s/'/\\'/g;
        $value = "'$value'" if $value =~ /[^0-9]/;
        $key = "'$key'" if $key =~ /^CF./;

        my $clause = { Key => $key, Op => $op, Value => $value };
        $node->addChild( __PACKAGE__->new( $clause ) );
    };
    $callback{'Error'} = sub { push @results, @_ };

    require RT::SQL;
    RT::SQL::Parse($string, \%callback);
    return @results;
}

eval "require RT::Interface::Web::QueryBuilder::Tree_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Interface/Web/QueryBuilder/Tree_Vendor.pm});
eval "require RT::Interface::Web::QueryBuilder::Tree_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Interface/Web/QueryBuilder/Tree_Local.pm});

1;
