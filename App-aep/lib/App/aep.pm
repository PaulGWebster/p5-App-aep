package App::aep;

# Internal perl
use 5.028;
use feature 'say';

# Internal perl modules
use warnings;
use strict;
use Data::Dumper;

# External modules 

# Version of this software
our $VERSION = '0.007';

=head1 NAME

App::aep - Advanced Entry Point (for docker and other containers)

=cut

sub new 
{
    my ($class,$callback) = @_;

    if (
        (!$callback) ||
        (ref $callback ne 'CODE')
    )
    {
        print STDERR "new() must be called with a reference to a function\n";
        print STDERR "An example of this would be ->new(\&my_handler)\n";
        exit 1;
    }

    my $self = bless {
        callback => $callback
    }, $class;

    foreach my $signal (keys %SIG) { 
        $SIG{$signal} = sub { &{$self->{callback}}($signal) };
    }

    return $self;
}

=head1 SYNOPSIS

=for comment Brief examples of using the module.

    From within your dockerfile, simply use cpan or cpanm to add App::aep

    It should then be possible to use 'aep' as the entrypoint in the dockerfile

    Please see the EXAMPLES section for a small dockerfile to create a working 
    example

=head1 DESCRIPTION

=for comment The module's description.

This app is a dynamic entry point for use in container systems such as docker, 
unlike most perl modules, this has been created to correctly react to signals
so it will respond correctly.

Signals passed to this entrypoint will also be passed down to the child.

=head1 ARGUMENTS

=head2 config related

=head3 --config-env

Default value: disabled

Only read command line options from the enviroment

=head3 --config-only

Default value: disabled

Only read command line options from the enviroment

=head3 --config-args

Default value: disabled

Only listen to command line arguments

=he

=head3 --config-merge (default)

Default value: enabled 

Merge together env, config and args to generate a config 

=head3 --config-order (default)

Default value: 'env,conf,args' (left to right)

The order to merge options together, 

=head2 environment related

=head3 --env-prefix (default)

Default value: aep_

When scanning the enviroment aep will look for this prefix to know which 
environment variables it should pay attention to.

=head1 BUGS

For any feature requests or bug reports please visit:

* Github L<https://github.com/PaulGWebster/p5-App-aep>

You may also catch up to the author 'daemon' on IRC:

* irc.freenode.net

* #perl

=head1 AUTHOR

Paul G Webster <daemon@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2019 by Paul G Webster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut 
1;