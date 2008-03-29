package RT::Graph::Tickets;

use strict;
use warnings;

=head1 NAME

RT::Graph::Tickets - view relations between tickets as graphs

=cut

use IPC::Run;
use IPC::Run::SafeHandles;
use GraphViz;

our %ticket_status_style = (
    new      => { fontcolor => '#FF0000' },
    open     => { fontcolor => '#000000' },
    stalled  => { fontcolor => '#DAA520' },
    resolved => { fontcolor => '#00FF00' },
    rejected => { fontcolor => '#808080' },
    deleted  => { fontcolor => '#A9A9A9' },
);

my %link_style = (
    MemberOf  => { style => 'solid' },
    DependsOn => { style => 'dashed', constraint => 'false' },
    RefersTo  => { style => 'dotted', constraint => 'false' },
);

my @fill_colors = qw(
    #0000FF #8A2BE2 #A52A2A #DEB887 #5F9EA0 #7FFF00 #D2691E #FF7F50
    #6495ED #FFF8DC #DC143C #00FFFF #00008B #008B8B #B8860B #A9A9A9
    #A9A9A9 #006400 #BDB76B #8B008B #556B2F #FF8C00 #9932CC #8B0000
    #E9967A #8FBC8F #483D8B #2F4F4F #2F4F4F #00CED1 #9400D3 #FF1493
    #00BFFF #696969 #696969 #1E90FF #B22222 #FFFAF0 #228B22 #FF00FF
    #DCDCDC #F8F8FF #FFD700 #DAA520 #808080 #808080 #008000 #ADFF2F
    #F0FFF0 #FF69B4 #CD5C5C #4B0082 #FFFFF0 #F0E68C #E6E6FA #FFF0F5
    #7CFC00 #FFFACD #ADD8E6 #F08080 #E0FFFF #FAFAD2 #D3D3D3 #D3D3D3
    #90EE90 #FFB6C1 #FFA07A #20B2AA #87CEFA #778899 #778899 #B0C4DE
    #FFFFE0 #00FF00 #32CD32 #FAF0E6 #FF00FF #800000 #66CDAA #0000CD
    #BA55D3 #9370D8 #3CB371 #7B68EE #00FA9A #48D1CC #C71585 #191970
    #F5FFFA #FFE4E1 #FFE4B5 #FFDEAD #000080 #FDF5E6 #808000 #6B8E23
    #FFA500 #FF4500 #DA70D6 #EEE8AA #98FB98 #AFEEEE #D87093 #FFEFD5
    #FFDAB9 #CD853F #FFC0CB #DDA0DD #B0E0E6 #800080 #FF0000 #BC8F8F
    #4169E1 #8B4513 #FA8072 #F4A460 #2E8B57 #FFF5EE #A0522D #C0C0C0
    #87CEEB #6A5ACD #708090 #708090 #FFFAFA #00FF7F #4682B4 #D2B48C
    #008080 #D8BFD8 #FF6347 #40E0D0 #EE82EE #F5DEB3 #FFFF00 #9ACD32
);

sub gv_escape($) {
    my $value = shift;
    $value =~ s{(?=")}{\\}g;
    return $value;
}

our (%fill_cache, @available_colors) = ();

sub TicketMembers {
    my $self = shift;
    my %args = (
        Ticket       => undef,
        Graph        => undef,
        Seen         => undef,
        Depth        => 0,
        CurrentDepth => 1,
        @_
    );
    unless ( $args{'Graph'} ) {
        $args{'Graph'} = GraphViz->new(
            name    => "ticket_members_". $args{'Ticket'}->id,
            bgcolor => "transparent",
            node    => { shape => 'box', style => 'rounded,filled', fillcolor => 'white' },
        );
        %fill_cache = ();
        @available_colors = @fill_colors;
    }

    $self->AddTicket( %args );

    $args{'Seen'} ||= {};
    return $args{'Graph'} if $args{'Seen'}{ $args{'Ticket'}->id }++;

    return $args{'Graph'} if $args{'Depth'} && $args{'CurrentDepth'} >= $args{'Depth'};

    my $show_link_descriptions = $args{'ShowLinkDescriptions'}
        && RT::Link->can('Description');

    my $to_links = $args{'Ticket'}->Links('Target', 'MemberOf');
    $to_links->GotoFirstItem;
    while ( my $link = $to_links->Next ) {
        my $base = $link->BaseObj;
        next unless $base->isa('RT::Ticket');

        $self->TicketMembers(
            %args,
            Ticket => $base,
            CurrentDepth => $args{'CurrentDepth'} + 1,
        );

        my $desc;
        $desc = $link->Description if $show_link_descriptions;
        $args{'Graph'}->add_edge(
            $args{'Ticket'}->id => $base->id,
            $desc? (label => gv_escape $desc): (),
        );
    }
    return $args{'Graph'};
};

my %property_cb = (
    Queue => sub { return $_[0]->QueueObj->Name || $_[0]->Queue },
    CF    => sub {
        my $values = $_[0]->CustomFieldValues( $_[1] );
        return join ', ', map $_->Content, @{ $values->ItemsArrayRef };
    },
);
foreach my $field (qw(Subject Status TimeLeft TimeWorked TimeEstimated)) {
    $property_cb{ $field } = sub { return $_[0]->$field },
}
foreach my $field (qw(Creator LastUpdatedBy Owner)) {
    $property_cb{ $field } = sub {
        my $method = $field .'Obj';
        return $_[0]->$method->Name;
    };
}
foreach my $field (qw(Requestor Cc AdminCc)) {
    $property_cb{ $field."s" } = sub {
        my $method = $field .'Addresses';
        return $_[0]->$method;
    };
}
foreach my $field (qw(Told Starts Started Due Resolved LastUpdated Created)) {
    $property_cb{ $field } = sub {
        my $method = $field .'Obj';
        return $_[0]->$method->AsString;
    };
}
foreach my $field (qw(Members DependedOnBy ReferredToBy)) {
    $property_cb{ $field } = sub {
        return join ', ', map $_->BaseObj->id, @{ $_[0]->$field->ItemsArrayRef };
    };
}
foreach my $field (qw(MemberOf DependsOn RefersTo)) {
    $property_cb{ $field } = sub {
        return join ', ', map $_->TargetObj->id, @{ $_[0]->$field->ItemsArrayRef };
    };
}


sub TicketProperties {
    my $self = shift;
    my $user = shift;
    my @res = (
        Basics => [qw(Subject Status Queue TimeLeft TimeWorked TimeEstimated)],
        People => [qw(Owner Requestors Ccs AdminCcs Creator LastUpdatedBy)],
        Dates  => [qw(Created Starts Started Due Resolved Told LastUpdated)],
        Links  => [qw(MemberOf Members DependsOn DependedOnBy RefersTo ReferredToBy)],
    );
    my $cfs = RT::CustomFields->new( $user );
    $cfs->LimitToLookupType('RT::Queue-RT::Ticket');
    $cfs->OrderBy( FIELD => 'Name' );
    my ($first, %seen) = (1);
    while ( my $cf = $cfs->Next ) {
        next if $seen{ lc $cf->Name }++;
        next if $cf->Type eq 'Image';
        if ( $first ) {
            push @res, 'CustomFields', [];
            $first = 0;
        }
        push @{ $res[-1] }, 'CF.{'. $cf->Name .'}';
    }
    return @res;
}

sub _SplitProperty {
    my $self = shift;
    my $property = shift;
    my ($key, @subkeys) = split /\./, $property;
    foreach ( grep /^{.*}$/, @subkeys ) {
        s/^{//;
        s/}$//;
    }
    return $key, @subkeys;
}

sub _PropertiesToFields {
    my $self = shift;
    my %args = (
        Ticket       => undef,
        Graph        => undef,
        CurrentDepth => 1,
        @_
    );

    my @properties;
    if ( my $tmp = $args{ 'Level-'. $args{'CurrentDepth'} .'-Properties' } ) {
        @properties = ref $tmp? @$tmp : ($tmp);
    }

    my @fields;
    foreach my $property( @properties ) {
        my ($key, @subkeys) = $self->_SplitProperty( $property );
        unless ( $property_cb{ $key } ) {
            $RT::Logger->error("Couldn't find property handler for '$key' and '@subkeys' subkeys");
            next;
        }
        push @fields, ($subkeys[0] || $key) .': '. $property_cb{ $key }->( $args{'Ticket'}, @subkeys );
    }

    return @fields;
}

sub AddTicket {
    my $self = shift;
    my %args = (
        Ticket       => undef,
        Properties   => [],
        Graph        => undef,
        CurrentDepth => 1,
        @_
    );

    my %node_style = (
        %{ $ticket_status_style{ $args{'Ticket'}->Status } || {} },
        URL   => $RT::WebPath .'/Ticket/Display.html?id='. $args{'Ticket'}->id,
        tooltip => gv_escape( $args{'Ticket'}->Subject || '#'. $args{'Ticket'}->id ),
    );

    my @fields = $self->_PropertiesToFields( %args );
    if ( @fields ) {
        unshift @fields, $args{'Ticket'}->id;
        $node_style{'label'} = gv_escape( '{ '. join( ' | ', map { s/(?=[{}|])/\\/g; $_ }  @fields ) .' }' );
        $node_style{'shape'} = 'record';
    }
    
    if ( $args{'FillUsing'} ) {
        my ($key, @subkeys) = $self->_SplitProperty( $args{'FillUsing'} );
        my $value = $property_cb{ $key }->( $args{'Ticket'}, @subkeys );
        if ( defined $value && length $value && $value =~ /\S/ ) {
            my $fill = $fill_cache{ $value };
            $fill = $fill_cache{ $value } = shift @available_colors
                unless $fill;
            if ( $fill ) {
                $node_style{'fillcolor'} = $fill;
                $node_style{'style'} ||= '';
                $node_style{'style'} = join ',', split( ',', $node_style{'style'} ), 'filled'
                    unless $node_style{'style'} =~ /\bfilled\b/;
            }
        }
    }

    $args{'Graph'}->add_node( $args{'Ticket'}->id, %node_style );
}

sub TicketLinks {
    my $self = shift;
    my %args = (
        Ticket   => undef,
        Graph    => undef,
        Seen     => undef,
        SeenEdge => undef,
        Depth    => 0,
        @_
    );
    unless ( $args{'Graph'} ) {
        $args{'Graph'} = GraphViz->new(
            name    => 'ticket_links_'. $args{'Ticket'}->id,
            bgcolor => "transparent",
            node => { shape => 'box', style => 'filled,rounded', fillcolor => 'white' },
        );
        %fill_cache = ();
        @available_colors = @fill_colors;
    }
    $self->AddTicket( %args );

    $args{'Seen'} ||= {};
    return $args{'Graph'} if $args{'Seen'}{ $args{'Ticket'}->id }++;

    return $args{'Graph'} if $args{'Depth'} && $args{'Depth'} == 1;

    $args{'SeenEdge'} ||= {};

    my $show_link_descriptions = $args{'ShowLinkDescriptions'}
        && RT::Link->can('Description');

    my $from_links = $args{'Ticket'}->Links('Base');
    $from_links->GotoFirstItem;
    while ( my $link = $from_links->Next ) {
        my $target = $link->TargetObj;
        next unless $target->isa('RT::Ticket');

        $self->TicketLinks(
            %args,
            Ticket => $target,
            Depth => $args{'Depth'}? $args{'Depth'} - 1 : 0,
        );
        next if $args{'SeenEdge'}{ $link->id }++;

        my $desc;
        $desc = $link->Description if $show_link_descriptions;
        $args{'Graph'}->add_edge(
            $link->Type eq 'MemberOf'
                ? ($target->id => $args{'Ticket'}->id)
                : ($args{'Ticket'}->id => $target->id),
            %{ $link_style{ $link->Type } || {} },
            $desc? (label => gv_escape $desc): (),
        );
    }

    my $to_links = $args{'Ticket'}->Links('Target');
    $to_links->GotoFirstItem;
    while ( my $link = $to_links->Next ) {
        my $base = $link->BaseObj;
        next unless $base->isa('RT::Ticket');

        $self->TicketLinks(
            %args,
            Ticket => $base,
            Depth => $args{'Depth'}? $args{'Depth'} - 1 : 0,
        );
        next if $args{'SeenEdge'}{ $link->id }++;

        my $desc;
        $desc = $link->Description if $show_link_descriptions;
        $args{'Graph'}->add_edge(
            $link->Type eq 'MemberOf'
                ? ($args{'Ticket'}->id => $base->id)
                : ($base->id => $args{'Ticket'}->id),
            %{ $link_style{ $link->Type } || {} },
            $desc? (label => gv_escape $desc): (),
        );
    }
    return $args{'Graph'};
}

1;