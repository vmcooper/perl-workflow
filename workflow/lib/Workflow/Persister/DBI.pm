package Workflow::Persister::DBI;

# $Id$

use strict;
use base qw( Workflow::Persister );
use DateTime::Format::Strptime;
use Log::Log4perl       qw( get_logger );
use Workflow::Exception qw( configuration_error persist_error );
use Workflow::History;

$Workflow::Persister::DBI::VERSION  = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);

my @FIELDS = qw( handle dsn user password driver
                 workflow_table history_table
                 workflow_id_generator history_id_generator );
__PACKAGE__->mk_accessors( @FIELDS );

sub init {
    my ( $self, $params ) = @_;
    unless ( $params->{dsn} ) {
        configuration_error "DBI persister configuration must include ",
                            "key 'dsn' which maps to the first paramter ",
                            "in the DBI 'connect()' call.";
    }
    my ( $dbi, $driver, $etc ) = split ':', $params->{dsn}, 3;
    $self->driver( $driver );
    $self->assign_generators( $driver, $params );
    $self->assign_tables( $params );


    for ( qw( dsn user password ) ) {
        $self->$_( $params->{ $_ } ) if ( $params->{ $_ } );
    }

    my $dbh = eval {
        DBI->connect( $self->dsn, $self->user, $self->password )
            || die "Cannot connect to database: $DBI::errstr";
    };
    if ( $@ ) {
        perist_error $@;
    }
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;
    $dbh->{ChopBlanks} = 1;
    $dbh->{AutoCommit} = 1;
    $self->handle( $dbh );
}

sub assign_generators {
    my ( $self, $driver, $params ) = @_;
    my ( $wf_gen, $history_gen );
    if ( $driver eq 'Pg' ) {
        ( $wf_gen, $history_gen ) =
            $self->init_postgres_generators( $params );
    }
    elsif ( $driver eq 'mysql' ) {
        ( $wf_gen, $history_gen ) =
            $self->init_mysql_generators( $params );
    }
    elsif ( $driver eq 'SQLite' ) {
        ( $wf_gen, $history_gen ) =
            $self->init_sqlite_generators( $params );
    }
    else {
        ( $wf_gen, $history_gen ) =
            $self->init_random_generators( $params );
    }
    $self->workflow_id_generator( $wf_gen );
    $self->history_id_generator( $history_gen );
}

sub init_postgres_generators {
    my ( $self, $params ) = @_;
    my $sequence_select = q{SELECT NEXTVAL( '%s' )};
    $params->{workflow_sequence} ||= 'workflow_seq';
    $params->{history_sequence}  ||= 'workflow_history_seq';
    return (
        Workflow::Persister::DBI::SequenceId->new(
            { sequence_name   => $params->{workflow_sequence},
              sequence_select => $sequence_select }),
        Workflow::Persister::DBI::SequenceId->new(
            { sequence_name   => $params->{history_sequence},
              sequence_select => $sequence_select })
    );
}

sub init_mysql_generators {
    my ( $self, $params ) = @_;
    my $generator =
        Workflow::Persister::DBI::AutoGeneratedId->new(
            { from_handle     => 'database',
              handle_property => 'mysql_insertid' });
    return ( $generator, $generator );
}

sub init_sqlite_generators {
    my ( $self, $params ) = @_;
    my $generator =
        Workflow::Persister::DBI::AutoGeneratedId->new(
            { func_property => 'last_insert_rowid' });
    return ( $generator, $generator );
}

sub init_random_generators {
    my ( $self, $params ) = @_;
    my $length = $params->{id_length} || 8;
    my $generator =
        Workflow::Persister::DBI::RandomId->new({ id_length => $length });
    return ( $generator, $generator );
}

sub assign_tables {
    my ( $self, $params ) = @_;
    my $wf_table   = $params->{workflow_table} || 'workflow';
    my $hist_table = $params->{history_table} || 'workflow_history';
    $self->workflow_table( $wf_table );
    $self->history_table( $hist_table );
}

########################################
# PERSISTENCE IMPLEMENTATION

sub create_workflow {
    my ( $self, $wf ) = @_;
    my $log = get_logger();
    my @fields = ( 'type',
                   'state',
                   'last_update' );
    my @values = ( $self->type,
                   $self->state,
                   DateTime->now->strftime( '%Y-%m-%d %H:%M' ) );
    my $id = $self->workflow_id_generator->pre_fetch_id;
    if ( $id ) {
        push @fields, 'workflow_id';
        push @values, $id;
        $log->debug( "Got ID from pre_fetch_id: $id" );
    }
    my $sql = q/
        INSERT INTO %s
        ( %s )
        VALUES ( %s )
    /;
    $sql = sprintf( $sql, $self->workflow_table,
                          join( ', ', @fields ),
                          join( ', ', map { '?' } 0 .. ( scalar @fields - 1 ) ));

    $log->debug( "Will use SQL\n$sql" );
    $log->debug( "Will use parameters\n", join( ', ', @values ) );

    my ( $sth );
    eval {
        $sth = $self->handle->prepare( $sql );
        $self->execute( @values );
    };
    if ( $@ ) {
        persist_error "Failed to create workflow: $@";
    }
    unless ( $id ) {
        $id = $self->workflow_id_generator->post_fetch_id( $self->handle, $sth );
        unless ( $id ) {
            persist_error "No ID found using generator '",
                          ref( $self->workflow_id_generator ), "'";
        }
    }
    $sth->finish;
    return $id;
}

sub update_workflow {
    my ( $self, $wf ) = @_;
    my $log = get_logger();
    my $sql = q/
        UPDATE %s
           SET state = ?,
               last_update = ?
         WHERE workflow_id = ?
    /;
    $sql = sprintf( $sql, $self->workflow_table );
    my $update_date = $wf->strftime( '%Y-%m-%d %H:%M' );

    $log->debug( "Will use SQL\n$sql" );
    $log->debug( "Will use parameters\n", join( ', ', $wf->state, $update_date, $wf->id ) );

    my ( $sth );
    eval {
        $sth = $self->handle->prepare( $sql );
        $sth->execute( $wf->state, $update_date, $wf->id );
    };
    if ( $@ ) {
        persist_error $@;
    }
}

sub fetch_workflow {
    my ( $self, $wf_id ) = @_;
    my $log = get_logger();
    my $sql = q/
        SELECT state FROM %s WHERE workflow_id = ?
    /;
    $sql = sprintf( $sql, $self->workflow_table );

    $log->debug( "Will use SQL\n$sql" );
    $log->debug( "Will use parameters: $wf_id" );

    my ( $sth );
    eval {
        $sth = $self->handle->prepare( $sql );
        $sth->execute( $wf_id );
    };
    my $row = $sth->fetchrow_arrayref;
    return { state => $row->[0] };
}

sub create_history {
    my ( $self, $wf, @history ) = @_;
    my $log = get_logger();
    my $dbh = $self->handle;
    my $generator = $self->history_id_generator;
    foreach my $h ( @history ) {
        my $id = $generator->pre_fetch_id( $dbh );
        my @fields = qw( workflow_id action description state
                         user history_date );
        my @values = ( $wf->id, $h->action, $h->description, $h->state,
                       $h->user, $h->date->strftime( '%Y-%m-%d %H:%M' ) );
        if ( $id ) {
            unshift @fields, 'workflow_hist_id';
            unshift @values, $id;
        }
        my $sql = q/
            INSERT INTO %s
            ( %s )
            VALUES ( %s )
        /;
        $sql = sprintf( $sql, $self->history_table,
                              join( ', ', @fields ),
                              join( ', ', map { '?' } 0 .. ( scalar @fields - 1 ) ) );

        $log->debug( "Will use SQL\n$sql" );
        $log->debug( "Will use parameters\n", join( ', ', @values ) );

        my ( $sth );
        eval {
            $sth = $dbh->prepare( $sth );
            $sth->execute( @values );
        };
        if ( $@ ) {
            persist_error $@;
        }
        unless ( $id ) {
            $id = $self->history_id_generator->post_fetch_id( $dbh, $sth );
            unless ( $id ) {
                persist_error "No ID found using generator '",
                              ref( $self->history_id_generator ), "'";
            }
        }
    }
}

sub fetch_history {
    my ( $self, $wf ) = @_;
    my $log = get_logger();
    my $sql = q/
        SELECT workflow_hist_id, workflow_id, action, description, state, user, history_date
          FROM %s
         WHERE workflow_id = ?
    /;

    $sql = sprintf( $sql, $self->history_table );

    $log->debug( "Will use SQL\n$sql" );
    $log->debug( "Will use parameters: ", $wf->id );

    my ( $sth );
    eval {
        $sth = $self->handle->prepare( $sql );
        $sth->prepare( $wf->id );
    };

    my $parser = DateTime::Format::Strftime->new( pattern => '%Y-%m-%d %H:%M:%S' );

    my @history = ();
    while ( my $row = $sth->fetchrow_arrayref ) {
        push @history, Workflow::History->new({
            id          => $row->[0],
            workflow_id => $row->[1],
            action      => $row->[2],
            description => $row->[3],
            state       => $row->[4],
            user        => $row->[5].
            date        => $parser->parse_datetime( $row->[6] ),
        });
    }
    $sth->finish;
    return @history;
}

1;

__END__

=head1 NAME

Workflow::Persister::DBI - Persist workflow and history to DBI database

=head1 SYNOPSIS

 <persister name="MainDatabase"
            class="Workflow::Persister::DBI"
            dsn="DBI:mysql:database=workflows"
            user="wf"
            password="mypass"/>
 
 <persister name="BackupDatabase"
            class="Workflow::Persister::DBI"
            dsn="DBI:Pg:dbname=workflows"
            user="wf"
            password="mypass"
            workflow_table="wf"
            workflow_sequence="wf_seq"
            history_table="wf_history"
            history_sequence="wf_history_seq"/>
 

=head1 DESCRIPTION

Main persistence class for storing the workflow and workflow history
records to a DBI-accessible datasource.

=head2 Subclassing

A common need to create a subclass is to use a database handle created
with other means. For instance, OpenInteract has a central
configuration file for defining datasources, and the datasource will
be available in a predictable manner. So we can create a subclass to
provide the database handle on demand from the C<CTX> object available
from everywhere. A sample implementation is below. (Note that in real
life we would just use SPOPS for this, but it is still a good
example.)

 package Workflow::Persister::DBI::OpenInteractHandle;
 
 use strict;
 use base qw( Workflow::Persister::DBI );
 use OpenInteract2::Context qw( CTX );
 
 my @FIELDS = qw( datasource_name );
 __PACKAGE__->mk_accessors( @FIELDS );
 
 # override parent method, assuming that we set the 'datasource'
 # parameter in the persister declaration
 
 sub init {
    my ( $self, $params ) = @_;
    $self->datasource_name( $params->{datasource} );
    my $ds_config = CTX->lookup_datasource_config( $self->datasource_name );

    # delegate the other assignment tasks to the parent class
 
    $self->assign_generators( $ds_config->{driver_name}, $params );
    $self->assign_tables( $params );
 }
 
 sub handle {
     my ( $self ) = @_;
     return CTX->datasource( $self->datasource_name );
 }

=head1 METHODS

=head2 Public Methods

All public methods are inherited from L<Workflow::Persister>.

=head2 Private Methods

B<init( \%params )>

Create a database handle from the given parameters. You are only
required to provide 'dsn', which is the full DBI DSN you normally use
as the first argument to C<connect()>.

You may also use:

=over 4

=item B<user>

Name of user to login with.

=item B<password>

Password for C<user> to login with.

=item B<workflow_table>

Table to use for persisting workflow. Default is 'workflow'.

=item B<history_table>

Table to use for persisting workflow history. Default is
'workflow_history'.

=back

You may also use parameters for the different types of ID
generators. See below under the C<init_*_generator> for the necessary
parameters for your database.

In addition to creating a database handle we parse the C<dsn> to see
what driver we are using to determine how to generate IDs. We have the
ability to use automatically generated IDs for PostgreSQL, MySQL, and
SQLite. If your database is not included a randomly generated ID will
be used. (Default length of 8 characters, which you can modify with a
C<id_length> parameters.)

You can also create your own adapter for a different type of
database. Just check out the existing
L<Workflow::Persister::DBI::AutoGeneratedId> and
L<Workflow::Persister::DBI::SequenceId> classes for examples.

B<assign_generators( $driver, \%params )>

Given C<$driver> and the persister parameters in C<\%params>, assign
the appropriate ID generators for both the workflow and history
tables.

Returns: nothing, but assigns the object properties
C<workflow_id_generator> and C<history_id_generator>.

B<assign_tables( \%params )>

Assign the table names from C<\%params> (using 'workflow_table' and
'history_table') or use the defaults 'workflow' and 'workflow_history'.

Returns: nothing, but assigns the object properties C<workflow_table>
and C<history_table>.

B<init_postgres_generators( \%params )>

Create ID generators for the workflow and history tables using
PostgreSQL sequences. You can specify the sequences used for the
workflow and history tables:

=over 4

=item B<workflow_sequence>

Sequence for the workflow table. Default: 'workflow_seq'

=item B<history_sequence>

Sequence for the workflow history table. Default:
'workflow_history_seq'

=back

B<init_mysql_generators( \%params )>

Create ID generators for the workflow and history tables using
the MySQL 'auto_increment' type. No parameters are necessary.

B<init_sqlite_generators( \%params )>

Create ID generators for the workflow and history tables using
the SQLite implicit increment. No parameters are necessary.

B<init_random_generators( \%params )>

Create ID generators for the workflow and history tables using
a random set of characters. You can specify:

=over 4

=item B<id_length>

Length of character sequence to generate. Default: 8.

=back

=head1 SEE ALSO

L<Workflow::Persister>

=head1 COPYRIGHT

Copyright (c) 2003 Chris Winters. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHORS

Chris Winters E<lt>chris@cwinters.comE<gt>
