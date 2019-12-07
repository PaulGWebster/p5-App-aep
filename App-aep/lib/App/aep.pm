package App::aep;

use strict;
use warnings;

use 5.028;
use feature 'say';
use Data::Dumper;

our $VERSION = '0.004';

=head1 NAME

App::aep - Module abstract placeholder text

=head1 SYNOPSIS

=for comment Brief examples of using the module.

=head1 DESCRIPTION

=for comment The module's description.

This app is a dynamic entry point for use in container systems such as docker
unlike most perl modules, this has been created to correctly react to signals
so it will exit cleanly and correctly.

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


1;

=head1 AUTHOR

Paul G Webster <daemon@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2019 by Paul G Webster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

