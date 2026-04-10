#!/usr/bin/env perl

package App::aep;

# ABSTRACT: Allows you to run a command within a container and control its start up

# Core
use warnings;
use strict;
use utf8;
use v5.28;

# Core - Modules
use Socket;
use Env qw(PATH HOME TERM);

# Core - Experimental (stable)
use experimental 'signatures';

# Debug
use Data::Dumper;
use Carp qw(cluck longmess shortmess);

# External
use POE qw(
    Session::PlainCall
    Wheel::SocketFactory
    Wheel::ReadWrite
    Wheel::Run
    Filter::Stackable
    Filter::Line
    Filter::JSONMaybeXS
);
use Try::Tiny;

# Version of this software
our $VERSION = '0.011';

# create a new blessed object, we will carry any passed arguments forward.
sub new ( $class, @args )
{
    my $self = bless { '_passed_args' => $args[ 0 ]->{ '_passed_args' }, }, $class;
    return $self;
}

# POE::Kernel's _start, in this case it also tells the kernel to capture signals
sub _start ( $self, @args )
{
    poe->kernel->sig( INT  => 'sig_int' );
    poe->kernel->sig( TERM => 'sig_term' );
    poe->kernel->sig( CHLD => 'sig_chld' );
    poe->kernel->sig( USR  => 'sig_usr' );

    my $debug = poe->heap->{ '_' }->{ 'debug' };
    $debug->( 'STDERR', __LINE__, 'Signals(INT,TERM,CHLD,USR) trapped.' );

    # What command are we meant to be running?
    my $opt = poe->heap->{ '_' }->{ 'opt' };

    # Initialize lock server order tracking
    if ( $opt->lock_server )
    {
        my $order_str = $opt->lock_server_order || '';
        my @order = grep { $_ ne '' } split( /,/, $order_str );
        poe->heap->{ 'lock' }->{ 'order' }         = \@order;
        poe->heap->{ 'lock' }->{ 'order_idx' }     = 0;
        poe->heap->{ 'lock' }->{ 'order_orig' }    = [ @order ];
        poe->heap->{ 'lock' }->{ 'waiting' }       = {};
        poe->heap->{ 'lock' }->{ 'unknown_queue' } = [];
    }

    # Initialize command state
    poe->heap->{ 'command' }                    = {};
    poe->heap->{ 'command' }->{ 'restart_count' } = 0;
    poe->heap->{ 'command' }->{ 'running' }     = 0;
    poe->heap->{ 'command' }->{ 'trigger_ok' }  = 0;

    if ( $opt->docker_health_check || $opt->lock_client )
    {
        poe->heap->{ 'services' }->{ 'afunixcli' } = POE::Session::PlainCall->create(
            'object_states' => [
                App::aep->new() => {
                    '_start'                     => 'afunixcli_client_start',
                    'afunixcli_server_connected' => 'afunixcli_server_connected',
                    'afunixcli_client_error'     => 'afunixcli_client_error',
                    'afunixcli_server_input'     => 'afunixcli_server_input',
                    'afunixcli_server_error'     => 'afunixcli_server_error',
                    'afunixcli_client_send'      => 'afunixcli_client_send',
                },
            ],
            'heap' => poe->heap,
        );
    }
    elsif ( $opt->lock_server )
    {
        poe->heap->{ 'services' }->{ 'afunixsrv' } = POE::Session::PlainCall->create(
            'object_states' => [
                App::aep->new() => {
                    '_start'                     => 'afunixsrv_server_start',
                    'afunixsrv_client_connected' => 'afunixsrv_client_connected',
                    'afunixsrv_server_error'     => 'afunixsrv_server_error',
                    'afunixsrv_client_input'     => 'afunixsrv_client_input',
                    'afunixsrv_client_error'     => 'afunixsrv_client_error',
                    'afunixsrv_server_send'      => 'afunixsrv_server_send'
                },
            ],
            'heap' => poe->heap,
        );
    }

    poe->kernel->yield( 'scheduler' );

    return;
}

# As server
sub afunixsrv_server_start
{
    my $socket_path = poe->heap->{ '_' }->{ 'config' }->{ 'AEP_SOCKETPATH' };
    poe->heap->{ 'afunixsrv' }->{ 'socket_path' } = $socket_path;

    if ( -e $socket_path )
    {
        unlink $socket_path;
    }

    poe->heap->{ 'afunixsrv' }->{ 'server' } = POE::Wheel::SocketFactory->new(
        'SocketDomain' => PF_UNIX,
        'BindAddress'  => $socket_path,
        'SuccessEvent' => 'afunixsrv_client_connected',
        'FailureEvent' => 'afunixsrv_server_error',
    );

    return;
}

# As client
sub afunixcli_client_start
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    my $socket_path = poe->heap->{ '_' }->{ 'config' }->{ 'AEP_SOCKETPATH' };
    poe->heap->{ 'afunixcli' }->{ 'socket_path' } = $socket_path;

    if ( !-e $socket_path )
    {
        $debug->( 'STDERR', __LINE__, "Control socket '$socket_path' does not exist, refusing to continue." );
        die;
    }

    poe->heap->{ 'afunixcli' }->{ 'client' } = POE::Wheel::SocketFactory->new(
        'SocketDomain'  => PF_UNIX,
        'RemoteAddress' => $socket_path,
        'SuccessEvent'  => 'afunixcli_server_connected',
        'FailureEvent'  => 'afunixcli_client_error',
    );

    return;
}

# As server
sub afunixsrv_server_error ( $self, $syscall, $errno, $error, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    if ( !$errno )
    {
        $error = "Normal disconnection.";
    }

    $debug->( 'STDERR', __LINE__, "Server AA socket encountered $syscall error $errno: $error" );

    delete poe->heap->{ 'services' }->{ 'afunixsrv' };
    return;
}

# As client
sub afunixcli_client_error ( $self, $syscall, $errno, $error, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    if ( !$errno )
    {
        $error = "Normal disconnection.";
    }

    $debug->( 'STDERR', __LINE__, "Client socket encountered $syscall error $errno: $error" );

    delete poe->heap->{ 'services' }->{ 'afunixcli' };
    return;
}

# As server
sub afunixsrv_client_connected ( $self, $socket, @args )
{

    # Generate an ID we can use
    my $client_id = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'id' }++;

    # Store the socket within it so it cannot go out of scope
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'socket' } = $socket;

    # Send a debug message for the event of a client connecting
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    $debug->( 'STDERR', __LINE__, "Client connected." );

    # Create a stackable filter so we can talk in json
    my $filter = POE::Filter::Stackable->new();
    $filter->push( POE::Filter::Line->new(), POE::Filter::JSONMaybeXS->new(), );

    # Create a rw_wheel to deal with the client
    my $rw_wheel = POE::Wheel::ReadWrite->new(
        'Handle'     => $socket,
        'Filter'     => $filter,
        'InputEvent' => 'afunixsrv_client_input',
        'ErrorEvent' => 'afunixsrv_client_error',
    );

    # Store the wheel next to the socket
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'wheel' } = $rw_wheel;

    # Store the filter so it never falls out of scope
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'filter' } = $filter;

    # Store tx/rx about the connection
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'tx_count' } = 0;
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'rx_count' } = 0;

    # Create a mapping from the wheelid to the client
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'cid2wid' }->{ $client_id } = $rw_wheel->ID;

    # And the other way
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'wid2cid' }->{ $rw_wheel->ID } = $client_id;

    # Also make a note under the obj, for cleaning up
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $client_id }->{ 'wid' } = $rw_wheel->ID;

    # Send a message to the connected client
    my $msg = { 'event' => 'hello' };
    poe->kernel->yield( 'afunixsrv_server_send', $client_id, $msg );

    return;
}

# As client
sub afunixcli_server_connected ( $self, $socket, @args )
{
    # Store the socket within it so it cannot go out of scope
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'obj' } = $socket;

    # Send a debug message for the event of a client connecting
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    $debug->( 'STDERR', __LINE__, "Server connected." );

    # Create a stackable filter so we can talk in json
    my $filter = POE::Filter::Stackable->new();
    $filter->push( POE::Filter::Line->new(), POE::Filter::JSONMaybeXS->new(), );

    # Create a rw_wheel to deal with the client
    my $rw_wheel = POE::Wheel::ReadWrite->new(
        'Handle'     => $socket,
        'Filter'     => $filter,
        'InputEvent' => 'afunixcli_server_input',
        'ErrorEvent' => 'afunixcli_server_error',
    );

    # Store the wheel next to the socket
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'wheel' } = $rw_wheel;

    # Store the filter so it never falls out of scope
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'filter' } = $filter;

    # Store tx/rx about the connection
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'tx_count' } = 0;
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'rx_count' } = 0;

    # Send our lock-id to the server so it knows who we are
    my $opt    = poe->heap->{ '_' }->{ 'opt' };
    my $msg    = { 'event' => 'hello', 'lock_id' => $opt->lock_id };
    poe->kernel->yield( 'afunixcli_client_send', $msg );

    return;
}

# As server
sub afunixsrv_server_send ( $self, $cid, $pkt )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'tx_count' }++;

    my $wheel = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'wheel' };

    # Format the packet, should be small
    my $packet = Dumper( $pkt );
    $packet =~ s#[\r\n]##g;
    $packet =~ s#\s+# #g;

    $debug->( 'STDERR', __LINE__, "Client($cid) TX: $packet" );

    $wheel->put( $pkt );

    return;
}

# As client
sub afunixcli_client_send ( $self, $pkt )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'tx_count' }++;

    my $wheel = poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'wheel' };

    # Format the packet, should be small
    my $packet = Dumper( $pkt );
    $packet =~ s#[\r\n]##g;
    $packet =~ s#\s+# #g;

    $debug->( 'STDERR', __LINE__, "Server(-) TX: $packet" );

    $wheel->put( $pkt );

    return;
}

# As server - handle input from a connected lock client
sub afunixsrv_client_input ( $self, $input, $wid )
{
    my $cid   = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'wid2cid' }->{ $wid };
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    # Increment the received packet count
    poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'rx_count' }++;

    # Shortcut to the wheel the client is connected to
    my $wheel = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'wheel' };

    # Format the packet, should be small
    my $packet = Dumper( $input );
    $packet =~ s#[\r\n]##g;
    $packet =~ s#\s+# #g;

    $debug->( 'STDERR', __LINE__, "Client($cid) RX: $packet" );

    my $event = $input->{ 'event' } || '';

    # Client is saying hello with its lock-id
    if ( $event eq 'hello' && defined $input->{ 'lock_id' } )
    {
        my $lock_id = $input->{ 'lock_id' };
        $debug->( 'STDERR', __LINE__, "Client($cid) identified as lock-id: $lock_id" );

        # Store the lock-id for this client
        poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'lock_id' } = $lock_id;

        # Map lock_id to cid for quick lookup
        poe->heap->{ 'lock' }->{ 'id2cid' }->{ $lock_id } = $cid;

        # Check if this client is next in the order
        _lock_server_check_next();
    }
    # Client is reporting that its lock-trigger passed (command started successfully)
    elsif ( $event eq 'trigger_ok' )
    {
        my $lock_id = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' }->{ $cid }->{ 'lock_id' } || 'unknown';
        $debug->( 'STDERR', __LINE__, "Client($cid) lock-id '$lock_id' reports trigger success." );

        # Advance to the next item in the order
        poe->heap->{ 'lock' }->{ 'order_idx' }++;
        _lock_server_check_next();
    }

    return;
}

# Check if the next client in the lock order is connected and ready
sub _lock_server_check_next
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };
    my $order = poe->heap->{ 'lock' }->{ 'order' };
    my $idx   = poe->heap->{ 'lock' }->{ 'order_idx' };

    # Check if we have exhausted the order list
    if ( $idx >= scalar( @{ $order } ) )
    {
        $debug->( 'STDERR', __LINE__, "Lock order list exhausted." );
        _lock_server_handle_exhaust();
        return;
    }

    my $next_id = $order->[ $idx ];
    $debug->( 'STDERR', __LINE__, "Lock order: checking for next lock-id '$next_id' (index $idx)." );

    # Check if this client is already connected and waiting
    my $cid = poe->heap->{ 'lock' }->{ 'id2cid' }->{ $next_id };
    if ( defined $cid )
    {
        $debug->( 'STDERR', __LINE__, "Lock-id '$next_id' is connected (cid $cid), sending run." );
        my $msg = { 'event' => 'run' };
        poe->kernel->yield( 'afunixsrv_server_send', $cid, $msg );
    }
    else
    {
        $debug->( 'STDERR', __LINE__, "Lock-id '$next_id' not yet connected, waiting." );
    }

    # Also process any unknown clients based on lock-server-default
    _lock_server_process_unknown();

    return;
}

# Handle unknown lock-ids based on --lock-server-default
sub _lock_server_process_unknown
{
    my $debug       = poe->heap->{ '_' }->{ 'debug' };
    my $opt         = poe->heap->{ '_' }->{ 'opt' };
    my $default_act = $opt->lock_server_default || 'ignore';
    my $order       = poe->heap->{ 'lock' }->{ 'order' };

    # Build a set of known lock-ids from the order list
    my %known = map { $_ => 1 } @{ $order };

    # Check all connected clients for unknown lock-ids
    my $clients = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'obj' } || {};
    for my $cid ( keys %{ $clients } )
    {
        my $lid = $clients->{ $cid }->{ 'lock_id' };
        next unless defined $lid;
        next if $known{ $lid };
        next if $clients->{ $cid }->{ 'unknown_handled' };

        if ( $default_act eq 'run' )
        {
            $debug->( 'STDERR', __LINE__, "Unknown lock-id '$lid' (cid $cid): sending run (default=run)." );
            my $msg = { 'event' => 'run' };
            poe->kernel->yield( 'afunixsrv_server_send', $cid, $msg );
            $clients->{ $cid }->{ 'unknown_handled' } = 1;
        }
        elsif ( $default_act eq 'runlast' )
        {
            # Queue it - will be processed after order list exhaustion
            push @{ poe->heap->{ 'lock' }->{ 'unknown_queue' } }, $cid
                unless grep { $_ == $cid } @{ poe->heap->{ 'lock' }->{ 'unknown_queue' } };
        }
        else
        {
            # ignore
            $debug->( 'STDERR', __LINE__, "Unknown lock-id '$lid' (cid $cid): ignoring (default=ignore)." );
            $clients->{ $cid }->{ 'unknown_handled' } = 1;
        }
    }

    return;
}

# Handle what happens when the lock order list is fully exhausted
sub _lock_server_handle_exhaust
{
    my $debug  = poe->heap->{ '_' }->{ 'debug' };
    my $opt    = poe->heap->{ '_' }->{ 'opt' };
    my $action = $opt->lock_server_exhaust_action || 'idle';

    # First, run any "runlast" queued unknowns
    my $queue = poe->heap->{ 'lock' }->{ 'unknown_queue' } || [];
    for my $cid ( @{ $queue } )
    {
        $debug->( 'STDERR', __LINE__, "Exhaust: sending run to queued unknown cid $cid." );
        my $msg = { 'event' => 'run' };
        poe->kernel->yield( 'afunixsrv_server_send', $cid, $msg );
    }
    poe->heap->{ 'lock' }->{ 'unknown_queue' } = [];

    if ( $action eq 'exit' )
    {
        $debug->( 'STDERR', __LINE__, "Lock order exhausted: exiting." );
        poe->heap->{ '_' }->{ 'set_exit' }->( '0', 'lock-order-exhausted' );
        poe->kernel->stop();
    }
    elsif ( $action eq 'restart' )
    {
        $debug->( 'STDERR', __LINE__, "Lock order exhausted: restarting order list." );
        poe->heap->{ 'lock' }->{ 'order_idx' } = 0;
        poe->heap->{ 'lock' }->{ 'order' }     = [ @{ poe->heap->{ 'lock' }->{ 'order_orig' } } ];
        poe->heap->{ 'lock' }->{ 'id2cid' }    = {};
    }
    elsif ( $action eq 'execute' )
    {
        $debug->( 'STDERR', __LINE__, "Lock order exhausted: starting own command." );
        poe->kernel->yield( 'command_start' );
    }
    else
    {
        # idle - do nothing, just keep the event loop alive
        $debug->( 'STDERR', __LINE__, "Lock order exhausted: idling." );
    }

    return;
}

# As client - handle input from the lock server
sub afunixcli_server_input ( $self, $input, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    # Increment the received packet count
    poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'rx_count' }++;

    # Shortcut to the wheel the client is connected to
    my $wheel = poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'wheel' };

    # Format the packet, should be small
    my $packet = Dumper( $input );
    $packet =~ s#[\r\n]##g;
    $packet =~ s#\s+# #g;

    $debug->( 'STDERR', __LINE__, "Server(-) RX: $packet" );

    my $event = $input->{ 'event' } || '';

    # Server says run - start our command
    if ( $event eq 'run' )
    {
        $debug->( 'STDERR', __LINE__, "Received 'run' from lock server, starting command." );
        poe->heap->{ 'command' }->{ 'lock_cleared' } = 1;
        poe->kernel->yield( 'command_start' );
    }

    return;
}

# As server
sub afunixsrv_client_error ( $self, $syscall, $errno, $error, $wid )
{
    my $cid   = poe->heap->{ 'afunixsrv' }->{ 'client' }->{ 'wid2cid' }->{ $wid };
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    if ( !$errno )
    {
        $error = "Normal disconnection for wheel: $wid, cid: $cid";
    }

    $debug->( 'STDERR', __LINE__, "Server session encountered $syscall error $errno: $error" );

    return;
}

# As client
sub afunixcli_server_error ( $self, $syscall, $errno, $error, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    if ( !$errno )
    {
        $error = "Normal disconnection for wheel: $wid";
    }

    $debug->( 'STDERR', __LINE__, "Server session encountered $syscall error $errno: $error" );

    return;
}

# --- Command execution via POE::Wheel::Run ---

# Start the child command process
sub command_start
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    # Do not start if already running
    if ( poe->heap->{ 'command' }->{ 'running' } )
    {
        $debug->( 'STDERR', __LINE__, "Command already running, skipping start." );
        return;
    }

    my $cmd      = $opt->command || 'aep --help';
    my $cmd_args = $opt->command_args || '';

    # Build the program + args array for Wheel::Run
    my @args = grep { $_ ne '' } split( /,/, $cmd_args );

    $debug->( 'STDERR', __LINE__, "Starting command: $cmd " . join( ' ', @args ) );

    # Reset trigger state for this run
    poe->heap->{ 'command' }->{ 'trigger_ok' } = 0;

    my $wheel = POE::Wheel::Run->new(
        'Program'     => $cmd,
        'ProgramArgs' => \@args,
        'StdoutEvent' => 'command_stdout',
        'StderrEvent' => 'command_stderr',
        'CloseEvent'  => 'command_close',
        'ErrorEvent'  => 'command_error',
    );

    poe->heap->{ 'command' }->{ 'wheel' }   = $wheel;
    poe->heap->{ 'command' }->{ 'pid' }     = $wheel->PID;
    poe->heap->{ 'command' }->{ 'running' } = 1;

    $debug->( 'STDERR', __LINE__, "Command started with PID: " . $wheel->PID );

    # Tell the kernel to watch this child
    poe->kernel->sig_child( $wheel->PID, 'sig_chld' );

    # If we are a lock client with a time-based trigger, set the timer now
    if ( $opt->lock_client )
    {
        _lock_trigger_setup();
    }

    return;
}

# Handle stdout from the child process
sub command_stdout ( $self, $line, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    # Pass through to our own stdout
    say STDOUT $line;

    # Check lock trigger if we are a lock client
    if ( $opt->lock_client && !poe->heap->{ 'command' }->{ 'trigger_ok' } )
    {
        _lock_trigger_check( 'stdout', $line );
    }

    return;
}

# Handle stderr from the child process
sub command_stderr ( $self, $line, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    # Pass through to our own stderr
    say STDERR $line;

    # Check lock trigger if we are a lock client
    if ( $opt->lock_client && !poe->heap->{ 'command' }->{ 'trigger_ok' } )
    {
        _lock_trigger_check( 'stderr', $line );
    }

    return;
}

# Handle child process close (all filehandles closed)
sub command_close ( $self, $wid )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    $debug->( 'STDERR', __LINE__, "Command process closed (wheel $wid)." );

    poe->heap->{ 'command' }->{ 'running' } = 0;
    delete poe->heap->{ 'command' }->{ 'wheel' };

    # Do not restart if we are shutting down
    if ( poe->heap->{ 'command' }->{ 'shutting_down' } )
    {
        $debug->( 'STDERR', __LINE__, "Command exited during shutdown, not restarting." );
        return;
    }

    # Check restart logic
    my $max_restart = $opt->command_restart || 0;
    my $no_restart  = $opt->command_norestart || 0;

    if ( $no_restart )
    {
        $debug->( 'STDERR', __LINE__, "Command exited, no-restart flag set." );
        poe->heap->{ '_' }->{ 'set_exit' }->( '0', 'command-exited-norestart' );
        return;
    }

    my $count = poe->heap->{ 'command' }->{ 'restart_count' };

    # -1 means infinite restarts, otherwise check the limit
    if ( $max_restart == -1 || $count < $max_restart )
    {
        poe->heap->{ 'command' }->{ 'restart_count' }++;
        my $delay_ms = $opt->command_restart_delay || 1000;
        my $delay_s  = $delay_ms / 1000;

        $debug->( 'STDERR', __LINE__,
            "Command exited, restarting in ${delay_ms}ms (attempt " . ( $count + 1 ) . ")." );
        poe->kernel->delay( 'command_start' => $delay_s );
    }
    else
    {
        $debug->( 'STDERR', __LINE__, "Command exited, max restarts ($max_restart) reached." );
        poe->heap->{ '_' }->{ 'set_exit' }->( '0', 'command-exited-max-restarts' );
    }

    return;
}

# Handle errors from the child process wheel
sub command_error ( $self, $syscall, $errno, $error, $wid, @extra )
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };

    # errno 0 on read means EOF, which is normal
    if ( !$errno )
    {
        return;
    }

    $debug->( 'STDERR', __LINE__, "Command wheel error: $syscall errno=$errno: $error" );

    return;
}

# --- Lock trigger logic ---

# Parse the lock-trigger spec and set up the appropriate watcher
sub _lock_trigger_setup
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    my $trigger = $opt->lock_trigger || 'none:time:10000';
    my ( $handle, $filter, $spec ) = split( /:/, $trigger, 3 );

    poe->heap->{ 'command' }->{ 'trigger' } = {
        'handle' => $handle || 'none',
        'filter' => $filter || 'time',
        'spec'   => $spec   || '10000',
    };

    $debug->( 'STDERR', __LINE__, "Lock trigger configured: handle=$handle filter=$filter spec=$spec" );

    # If the trigger is time-based, set up a delay
    if ( $filter eq 'time' )
    {
        my $delay_ms = $spec || 10000;
        my $delay_s  = $delay_ms / 1000;
        $debug->( 'STDERR', __LINE__, "Time-based trigger: will fire in ${delay_ms}ms." );
        poe->kernel->delay( 'lock_trigger_fire' => $delay_s );
    }
    # If the trigger is connect-based, try a TCP connection
    elsif ( $filter eq 'connect' )
    {
        $debug->( 'STDERR', __LINE__, "Connect-based trigger: will try connecting to $spec." );
        poe->kernel->delay( 'lock_trigger_connect' => 1 );
    }
    # If the trigger is script-based, run the script
    elsif ( $filter eq 'script' )
    {
        $debug->( 'STDERR', __LINE__, "Script-based trigger: will run $spec." );
        poe->kernel->delay( 'lock_trigger_script' => 1 );
    }
    # text and regex triggers are checked inline via _lock_trigger_check

    return;
}

# Check a line of output against text/regex triggers
sub _lock_trigger_check ( $source, $line )
{
    my $debug   = poe->heap->{ '_' }->{ 'debug' };
    my $trigger = poe->heap->{ 'command' }->{ 'trigger' };

    return unless $trigger;

    my $handle = $trigger->{ 'handle' };
    my $filter = $trigger->{ 'filter' };
    my $spec   = $trigger->{ 'spec' };

    # Check if this source matches the handle
    return if ( $handle eq 'stdout' && $source ne 'stdout' );
    return if ( $handle eq 'stderr' && $source ne 'stderr' );
    # 'both' and 'none' match everything (none has no output filter)

    if ( $filter eq 'text' )
    {
        if ( index( $line, $spec ) != -1 )
        {
            $debug->( 'STDERR', __LINE__, "Text trigger matched: '$spec' found in $source output." );
            poe->kernel->yield( 'lock_trigger_fire' );
        }
    }
    elsif ( $filter eq 'regex' )
    {
        if ( $line =~ m{$spec} )
        {
            $debug->( 'STDERR', __LINE__, "Regex trigger matched: /$spec/ found in $source output." );
            poe->kernel->yield( 'lock_trigger_fire' );
        }
    }

    return;
}

# Fire the lock trigger - report success to the lock server
sub lock_trigger_fire
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    # Only fire once
    if ( poe->heap->{ 'command' }->{ 'trigger_ok' } )
    {
        return;
    }

    poe->heap->{ 'command' }->{ 'trigger_ok' } = 1;

    $debug->( 'STDERR', __LINE__, "Lock trigger fired, reporting success to server." );

    # Send trigger_ok to the lock server
    if ( poe->heap->{ 'afunixcli' }->{ 'server' }->{ 'wheel' } )
    {
        my $msg = { 'event' => 'trigger_ok', 'lock_id' => $opt->lock_id };
        poe->kernel->yield( 'afunixcli_client_send', $msg );
    }

    return;
}

# Attempt a TCP connect for the connect trigger type
sub lock_trigger_connect
{
    my $debug   = poe->heap->{ '_' }->{ 'debug' };
    my $trigger = poe->heap->{ 'command' }->{ 'trigger' };
    my $spec    = $trigger->{ 'spec' } || '';

    # Already triggered
    return if poe->heap->{ 'command' }->{ 'trigger_ok' };

    # Parse host:port from spec
    my ( $host, $port ) = split( /:/, $spec, 2 );
    if ( !$host || !$port )
    {
        $debug->( 'STDERR', __LINE__, "Connect trigger: invalid spec '$spec', expected host:port." );
        return;
    }

    $debug->( 'STDERR', __LINE__, "Connect trigger: trying $host:$port." );

    my $sock;
    my $ok = try {
        socket( $sock, PF_INET, SOCK_STREAM, getprotobyname( 'tcp' ) ) || return 0;
        my $addr = sockaddr_in( $port, inet_aton( $host ) );
        connect( $sock, $addr ) || return 0;
        close( $sock );
        return 1;
    }
    catch {
        return 0;
    };

    if ( $ok )
    {
        $debug->( 'STDERR', __LINE__, "Connect trigger: connection to $host:$port succeeded." );
        poe->kernel->yield( 'lock_trigger_fire' );
    }
    else
    {
        # Retry after 1 second
        poe->kernel->delay( 'lock_trigger_connect' => 1 );
    }

    return;
}

# Run an external script for the script trigger type
sub lock_trigger_script
{
    my $debug   = poe->heap->{ '_' }->{ 'debug' };
    my $trigger = poe->heap->{ 'command' }->{ 'trigger' };
    my $spec    = $trigger->{ 'spec' } || '';

    # Already triggered
    return if poe->heap->{ 'command' }->{ 'trigger_ok' };

    $debug->( 'STDERR', __LINE__, "Script trigger: running '$spec'." );

    my $exit_code = system( $spec );

    if ( $exit_code == 0 )
    {
        $debug->( 'STDERR', __LINE__, "Script trigger: '$spec' exited 0 (success)." );
        poe->kernel->yield( 'lock_trigger_fire' );
    }
    else
    {
        $debug->( 'STDERR', __LINE__, "Script trigger: '$spec' exited non-zero, retrying." );
        poe->kernel->delay( 'lock_trigger_script' => 1 );
    }

    return;
}

# --- Signal handlers ---

sub sig_int
{

    # Set an appropriate exit
    poe->heap->{ '_' }->{ 'set_exit' }->( '1', 'sigint' );

    # Announce the event
    poe->heap->{ '_' }->{ 'debug' }->( 'STDERR', __LINE__, 'Signal: INT - starting controlled shutdown.' );

    # Tell the kernel to ignore the term we are handling it
    poe->kernel->sig_handled();

    # Send kill to the child process if running
    if ( poe->heap->{ 'command' }->{ 'wheel' } )
    {
        poe->heap->{ 'command' }->{ 'wheel' }->kill( 'INT' );
    }

    # Prevent restarts during shutdown
    poe->heap->{ 'command' }->{ 'shutting_down' } = 1;

    # Stop the event wheel
    poe->kernel->stop();

    return;
}

sub sig_term
{

    # Set an appropriate exit
    poe->heap->{ '_' }->{ 'set_exit' }->( '1', 'sigterm' );

    # Announce the event
    poe->heap->{ '_' }->{ 'debug' }->( 'STDERR', __LINE__, 'Signal: TERM - starting controlled shutdown.' );

    # Tell the kernel to ignore the term we are handling it
    poe->kernel->sig_handled();

    # Send kill to the child process if running
    if ( poe->heap->{ 'command' }->{ 'wheel' } )
    {
        poe->heap->{ 'command' }->{ 'wheel' }->kill( 'TERM' );
    }

    # Prevent restarts during shutdown
    poe->heap->{ 'command' }->{ 'shutting_down' } = 1;

    # Stop the event wheel
    poe->kernel->stop();

    return;
}

sub sig_chld
{

    # Announce the event
    poe->heap->{ '_' }->{ 'debug' }->( 'STDERR', __LINE__, 'Signal CHLD received.' );

    # Let POE handle the child reaping
    poe->kernel->sig_handled();

    return;
}

sub sig_usr
{

    # Announce the event
    poe->heap->{ '_' }->{ 'debug' }->( 'STDERR', __LINE__, 'Signal USR, ignoring' );

    return;
}

# --- Scheduler ---

# The scheduler decides what to do based on the operating mode
sub scheduler
{
    my $debug = poe->heap->{ '_' }->{ 'debug' };
    my $opt   = poe->heap->{ '_' }->{ 'opt' };

    if ( $opt->lock_client )
    {
        # Lock client mode: wait for the server to tell us to run
        # The afunixcli_server_input handler will yield command_start when it receives "run"
        $debug->( 'STDERR', __LINE__, "Scheduler: lock-client mode, waiting for server signal." );
    }
    elsif ( $opt->lock_server )
    {
        # Lock server mode: listen for connections and process the order
        # The afunixsrv_client_input handler manages the ordering protocol
        $debug->( 'STDERR', __LINE__, "Scheduler: lock-server mode, listening for clients." );
    }
    else
    {
        # Standalone mode: start the command immediately
        $debug->( 'STDERR', __LINE__, "Scheduler: standalone mode, starting command." );
        poe->kernel->yield( 'command_start' );
    }

    return;
}

__END__

=head1 SYNOPSIS

=for comment Brief examples of using the module.

    shell$ aep --help

=head1 DESCRIPTION

=for comment The module's description.

AEP (Advanced Entry Point) is a container entrypoint tool that runs commands
within Docker containers and provides a lock server/client mechanism for
orchestrating multi-container startup order.

=head1 ARGUMENTS

=head2 config related

=head3 config-env

Default value: disabled

Only read command line options from the enviroment

=head3 config-file

Default value: disabled

Only read command line options from the enviroment

=head3 config-args

Default value: disabled

Only listen to command line arguments

=head3 config-merge (default)

Default value: enabled

Merge together env, config and args to generate a config

=head3 config-order (default)

Default value: 'env,conf,args' (left to right)

The order to merge options together,

=head2 environment related

=head3 env-prefix (default)

Default value: aep-

When scanning the enviroment aep will look for this prefix to know which
environment variables it should pay attention to.

=head2 Command related (what to run)

=head3 command (string)

What to actually run within the container, default is print aes help.

=head3 command-args (string)

The arguments to add to the command comma seperated, default is nothing.

Example: --list,--as-service,--with-long "arg",--foreground

=head3 command-restart (integer)

If the command exits how many times to retry it, default 0 set to -1 for infinate

=head3 command-restart-delay (integer)

The time in milliseconds to wait before retrying the command, default 1000

=head2 Lock commands (server)

These are for if you have concerns of 'race' conditions.

=head3 lock-server

Default value: disabled

Act like a lock server, this means we will expect other aeps to connect to us,
we in turn will say when they should actually start, this is to counter-act
race issues when starting multi image containers such as docker-compose.

=head3 lock-server-host (string)

What host to bind to, defaults to 0.0.0.0

=head3 lock-server-port (integer)

What port to bind to, defaults to 60000

=head3 lock-server-default (string)

Default value: ignore

If we get sent an ID we do not know what to do with, the action to take.
Valid options are: "ignore", "run" or "runlast".

=head3 lock-server-order (string)

The list of ids and the order to allow them to run, allows OR || operators, for
example: db,redis1||redis2,redis1||redis2,nginx

Beware the the lock-server-default config flag!

=head3 lock-server-exhaust-action (string)

Default value: idle

What to do if all clients have been started (list end), options are:


=over 4

=item *

exit - Exit 0

=item *

idle - Do nothing, just sit there doing nothing

=item *

restart - Reset the lock-server-order list and continue operating

=item *

execute - Read in any passed commands and args and run them like a normal aep

=back

=head2 Lock commands (client)

=head3 lock-client

Default value: disabled

Become a lock client, this will mean your aep will connect to another aep to
learn when it should run its command.

=head3 lock-client-host (string)

What host to connect to, defaults to 'aep-master'

=head3 lock-client-port (integer)

What port to connect to, defaults to 60000

=head3 lock-trigger (string)

Default: none:time:10000

What to look for to know that our target command has executed correctly, if the
target command dies or exits before this filter can complete, the success will
never be reported, if you have also set restart options the lock-trigger will
continue to try to validate the service.

The syntax for the filters is:

    handle:filter:specification

handle can be stderr, stdout, both or none

So an example for a filter that will match 'now serving requests':

    both:text:now serving requests

Several standard filters are availible:

=over 4

=item *

time - Wait this many milliseconds and then report success.

Example: none:time:2000

=item *

regex - Wait till this regex matches to report success.

Example: both:regex:ok|success

=item *

text - Wait till this line of text is seen.

Example: both:text:success

=item *

script - Run a script or binary somewhere else on the system and use its exit
code to determine success or failure.

Example: none:script:/opt/check_state

=item *

connect - Try to connect to a tcp port, no data is sent and any recieved is
ignored. Will be treated as success if the connect its self succeeds.

Example: none:connect:127.0.0.1:6767

=back

=head3 lock-id (string)

What ID we should say we are

=head1 BUGS

For any feature requests or bug reports please visit:

* Github L<https://github.com/PaulGWebster/p5-App-aep>

You may also catch up to the author 'daemon' on IRC:

* irc.libera.org

* #perl

=head1 AUTHOR

Paul G Webster <daemon@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2023 by Paul G Webster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

1;
