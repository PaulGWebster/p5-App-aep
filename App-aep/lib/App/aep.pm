package App::aep;

use strict;
use warnings;

use 5.028;
use feature 'say';

our $VERSION = '0.001';

sub new {
  my ($class,$options) = @_;

  my $self = bless {
  }, $class;

  return $self;
}

sub hello {
    my ($self,$msg) = @_;

    return $msg // "";
}

1;

=head1 NAME

App::aep - Module abstract placeholder text

=head1 SYNOPSIS

=for comment Brief examples of using the module.

=head1 DESCRIPTION

=for comment The module's description.

=head1 AUTHOR

Paul G Webster <daemon@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2019 by Paul G Webster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

