package Test::Mock::Object;

# ABSTRACT: Dead-simple mocking

use strict;
use warnings;

use 5.22.0;
use warnings;
use Carp 'croak';
use Sub::Name;
use Sub::Identify qw(sub_name);
use Scalar::Util 'blessed';
use Test::Mock::Object::Chain 'create_method_chain';
use Exporter 'import';

our $VERSION = '0.2';

our @EXPORT_OK = qw(
  create_mock
  read_only
  add_method
  reset_mocked_calls
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

sub create_mock {
    my (%arg_for) = @_;
    state $mock_number = {};
    my $package = delete $arg_for{package} || croak("Package required");

    # this will block $package from being loaded if it wasn't already loaded
    my $file = "$package.pm";
    $file =~ s{::}{/}g;

    $INC{$file} ||= 'Mocked by Test::Mock::Object';

    # now remove the :: so we don't need to dynamically walk down namespaces
    my $munged_package = $package;
    $munged_package =~ s/::/_/g;
    my $mock_package =
      "MockMeAmadeus::${munged_package}_V" . ++$mock_number->{$munged_package};
    my $methods = delete $arg_for{methods}       || {};
    my $chains  = delete $arg_for{method_chains} || [];
    my $mock_object = bless {}, $mock_package;

    my $namespace = _namespace($mock_package);
    foreach my $method_name ( keys %$methods ) {
        add_method( $mock_object, $method_name, $methods->{$method_name} );
    }

    # must add method chains after methods
    foreach my $chain (@$chains) {
        _add_chain( $mock_object, $chain );
    }

    # if they want to supply their own isa(), fine.
    if ( not exists $methods->{isa} ) {
        add_method(
            $mock_object,
            'isa',
            sub {
                my ( $class, $maybe_class ) = @_;
                return $package eq $maybe_class
                  || $mock_package eq $maybe_class;
            }
        );
    }
    add_method( $mock_object, '__original__package__name',
        read_only($package) );
    add_method(
        $mock_object,
        'DESTROY',
        sub {

            # delete this package on DESTROY or else we'll leak memory
            delete ${MockMeAmadeus::}{$namespace};
        }
    );
    return $mock_object;
}

sub _should_track_method {
    my $method_name = shift;
    state $ignore_this = {
        __original__package__name => 1,
        DESTROY                   => 1,
    };
    return not $ignore_this->{$method_name};
}

sub add_method {
    my ( $mock_object, $method_name, $method ) = @_;

    my $should_track_method = _should_track_method($method_name);
    if ($should_track_method) {
        $mock_object->{$method_name} = {
            times_with_args    => 0,
            times_without_args => 0,
            times_called       => 0,
        };
    }

    if ( blessed $method && $method->isa('Test::Mock::Object::Chain') ) {

        # if we're being passed a method chain, ensure we only return the
        # chain. Otherwise, the 'elsif' logic kicks in and chains fail
        # if arguments are passed to the *first* method in the chain because
        # the arguments will get returned instead of the chain
        my $chain = $method;
        $method = sub { $chain };
    }
    elsif ( !defined $method || 'CODE' ne ref $method ) {
        my $this_value = $method;
        $method = sub {
            state $value = $this_value;
            my $self = shift;
            if (@_) {
                $value = shift;
            }
            return $value;
        };
    }

    # this ensures that we can always track how many
    # times a method was called, even if they supply
    # their own coderef
    my $final_method = $should_track_method
      ? sub {
        my $self = shift;
        $self->{$method_name}{times_called}++;
        if (@_) {
            $self->{$method_name}{times_with_args}++;
        }
        else {
            $self->{$method_name}{times_without_args}++;
        }

        # if they passed in a code reference that uses wantarray, we'll break
        # their code unless we respect that
        return wantarray ? $self->$method(@_) : scalar $self->$method(@_);
      }
      : $method;

    subname $method_name, $final_method;
    subname $method_name, $method;

    # The _namespace function returns the part of the namespace *after*
    # MockMeAmadeus::, (but with a '::' affixed) so this weird structure
    # lets us add to the MockMeAmadeus:: namespace without disabling
    # strict
    ${MockMeAmadeus::}{ _namespace( ref $mock_object ) }{$method_name} =
      $final_method;
}

sub _add_chain {
    my ( $mock_object, $method_chain ) = @_;

    my $method = shift @$method_chain;

    my $already_exists = 0;
    if ( $mock_object->can($method) ) {
        $already_exists = 1;
        my $value = $mock_object->$method;
        if ( blessed $value && $value->isa('Test::Mock::Object::Chain') ) {
            $method_chain->[0] = [ $value, $method_chain->[0] ];
        }
        else {
            my $class = ref $mock_object;

            croak(
"Cannot create method chain for $class while overridding an existing method: $method"
            );
        }
    }
    my $return_value =
      1 == @$method_chain
      ? $method_chain->[0]
      : create_method_chain($method_chain);
    add_method( $mock_object, $method, $return_value ) unless $already_exists;
}

sub reset_mocked_calls {
    my $mock = shift;
    foreach my $method ( keys %$mock ) {
        $mock->{$method} = {
            times_with_args    => 0,
            times_without_args => 0,
            times_called       => 0,
        };
    }
}

sub _namespace {
    my $package = shift;
    my ( $first, $namespace ) = split /::/, $package, 2;
    unless ( $first eq 'MockMeAmadeus' ) {
        croak("Trying to to fetch namespace from unmocked package: $package");
    }
    if ( $namespace =~ /::/ ) {
        croak(
"Malformed package name. Only on sublevel of namespace allowed: $package"
        );
    }
    return "${namespace}::";
}

sub read_only {
    my $value = shift;
    return sub {
        my $self = shift;
        if (@_) {
            my $package = $self->__original__package__name;
            my $method  = sub_name(__SUB__);
            croak("$package->$method is read-only");
        }
        $value;
    };
}

1;

__END__

=head1 SYNOPSIS

  use Test::Mock::Object qw(create_mock read_only);
  
  my $r = create_mock(
      package => 'Apache2::RequestRec',
      methods => {
          uri        => read_only('/foo/bar'),
          status     => undef,                   # read/write method
          headers_in => {},
          param      => sub {
              my ( $self, $param ) = @_;
              my %value_for = (
                  skip_this => 1,
                  thing_id  => 1001,
              );
              return $value_for{$param};
          },
      },
      method_chains => [                         # arrayref
          [ qw/foo bar baz/ => $final_value ],    # of arrayrefs
      ],
  );

=head1 DESCRIPTION

Mock objects can be a controversial topic, but sometimes they're very useful.
However, mock objects in Perl often come in two flavors:

=over 4

=item * Incomplete mocks of existing modules

=item * Generic mocks with clumsy interfaces I can never remember

=back

This module is my attempt to make things dead-easy. Here's a simple mock object:

    my $mock = create_mock(
        package => 'Toy::Soldier',
        methods => {
            name   => 'Ovid',
            rank   => 'Private',
            serial => '123-456-789',
        }
    );

You can figure out what that does and it's easy. However, we have a lot more.

Note, that while C<< $mocked->isa($package) >> will return true for the name
of the package you're mocking, but the package will be blessed into a
namespace similar to C<MockMeAmadeus::$compact_package>, where
C<$compact_package> is the name of the blessed package, but with C<::>
replaced with underscores, along with a prepended C<_V$mock_number>. Thus,
mocking something into the C<Foo::Bar> package would cause C<ref> to return
something like C<MockMeAmadeus::Foo_Bar_b1>.

If you need something more interesting for C<isa>, pass in your own:

    my $mock = create_mock(
        package => 'Toy::Soldier',
        methods => {
            name   => 'Ovid',
            rank   => 'Private',
            serial => '123-456-789',
            isa    => sub {
                my ( $self, $class ) = @_;
                return $class eq 'Toy::Soldier' || $class eq 'Toy';
            },
        }
    );

=head1 FUNCTIONS

These functions are exportable individually or with C<::all>:

  use Test::Mock::Object qw(
    add_method
    create_mock
    read_only
    reset_mocked_calls
  );
  # same as
  use Test::Mock::Object ':all';


=head2 C<< create_mock( package => $package, methods => \%methods ) >>

  use Test::Mock::Object qw(create_mock read_only);

  my $r = create_mock(
      package => 'Apache2::RequestRec',
      methods => {
          uri        => read_only('/foo/bar'),
          status     => undef,                   # read/write method
          headers_in => {},
          param      => sub {
              my ( $self, $param ) = @_;
              my %value_for = (
                  skip_this => 1,
                  thing_id  => 1001,
              );
              return $value_for{$param};
          },
      }
      method_chains => [                          # arrayref
          [ qw/foo bar baz/ => $final_value ],    # of arrayrefs
      ],
  );
  say $r->uri;                 # /foo/bar
  say $r->param('thing_id');   # 1001
  say $r->status;              # undef
  $r->status(404);
  say $r->status;              # 404
  $r->uri($new_value);         # fatal error
  say $r->foo->bar->baz;       # $final_value (from method_chains)

We simply declare the package and the methods we need. If the package has not
yet been loaded, we alter C<%INC> to ensure the package cannot be loaded after
this. This is a convenience if we have a module that's very hard to load.

As for the methods, if we point to a coderef, that's the method. If we point to
I<anything else>, the method will return that value and you can set it to a new
value.

Arguments to C<create_mock()> are:

=over 4

=item * C<package>

The name of the package we will mock.

Required.

=item * C<methods>

Key/Value pairs of methods. Keys are method names of the objects and values
what those methods return, with one important exception.

If the value is a subroutine reference, that reference I<becomes> the method
for the key. If you want a method to I<return> a subroutine reference, you
need to wrap that in another subroutine reference.

    method => sub { sub { ... } }

Optional.

=item * C<method_chains>

(Still experimental)

An array reference of array references. Optional.

    my $mock = create_mock(
        package => 'Some::Package',
        method_chains => [
            [ qw/ name to_string Ovid / ],
            [ qw/ name reversed divO / ],
            [ qw/ foo bar baz 42 / ],
        ]
    );
    say $mock->name->to_string;     # Ovid
    say $mock->name->reversed;      # divO
    say $mock->foo->bar->baz;       # 42

We have incomplete support for chains that might start
with the same method.

=back

=head2 C<read_only($value)>

When used with a method value, will throw a fatal error if
you try to set that value:

    uri => read_only('/foo/bar')

=head2 C<add_method($mock_object, $method_name, $value)>

Just like the key/value pairs to C<create_mock()>, this adds a getter/setter
for C<$value>.  If C<$value> is a code reference, it will be added directly as
the method. You can make the value read-only, if needed:

    add_method($mock_object, 'created', read_only(DateTime->now));

=head2 C<reset_mocked_calls($mock_object)>

    reset_mocked_calls($mock_object);

This reset the "times called" internals to 0 for every method. See L</"Inside
the object">.

=head1 Mocked Methods

=head2 C<isa>

    if ( $r->isa('Apache2::RequestRec') ) {
        ...
    }

Returns true if the classname passed in matches the name passed to C<create_mock>

=head1 Inside the object

The object returned encapsulates all data thoroughly. However, it's a blessed
hashref whos keys are the names of the methods, each pointing to hashref with
information about how they were called in the code. So our example above would
have this:

    bless(
        {
            'foo' => {
                'times_called'       => 1,
                'times_with_args'    => 0,
                'times_without_args' => 1
            },
            'headers_in' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            },
            'isa' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            },
            'param' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            },
            'some_object' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            },
            'status' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            },
            'uri' => {
                'times_called'       => 0,
                'times_with_args'    => 0,
                'times_without_args' => 0
            }
        },
        'MockMeAmadeus::Apache2_RequestRec_V1'
      )

C<times_called> is the number of times that method was called in the code
you're using it in.

C<times_with_args> is the number of times that method was called
with arguments.

C<times_without_args> is the number of times that method was called without
arguments.

=head1 Unknown methods

The methods you request are the methods you will receive. Any attempt to call
unknown methods will be a fatal error.

=head1 BEST PRACTICES

=head2 Don't Use Mock Objects

See L</Interface Changes>. However, if you're relying on sometthing you don't
control, such as an object that requires a database connection or an internet
connection, a mock might be acceptable.

=head2 Only Mock the Methods You Use

You might be tempted to mock every single method in an interface. Don't do that.
Only mock the methods that you actually use. That way, if the code is updated to
call a method you didn't mock, your test with fail with a "Method not found"
error.

=head1 LIMITATIONS

Be aware that while mock objects can be useful, there are several limitations
to be aware of.

=head2 Interface Changes

In theory, objects should be open for extension, closed for modification.

In practice, we have deadlines, we make mistakes, needs evolve, whatever. If
your mock object mocks an instance of C<Foo::Bar> and you install a new
version of C<Foo::Bar> with a different interface, your mock may very well
hide the fact that your code is broken.

=head2 Encapsulation Violations

Constantly you see developers do things like this:

    # don't reach inside!
    my $name = $object->{name};

And:

    # this should be an ->isa check
    if ( ref $object eq 'Toy::Soldier' ) {
        ...
    }

Both of those will fail with C<Test::Mock::Object>. This is by design to avoid
the temptation to ignore these issues. This might mean that
C<Test::Mock::Object> is not suitable for your needs.

=head2 We Changes Instances, Not Classes

Thus, if you mock an instance of a base class, subclasses won't see that (and
other instances won't see that either). Instead, you might find L<Mock::Quick>
useful. L<Test::MockModule> might also help, or if you just need to replace one
or two methods in a lexical scope, see L<Sub::Override>.

=head1 NOTES

=head2 Memory Leak Protection

If you install L<Test::LeakTrace>, a test in our test suite will verify that
we do not have memory leaks. I've only tested this on a couple of versions of
Perl. It's possible that some versions will leak. Please let me know if this
happens.

=head2 Chained Methods

Method chains are often a code smell. You can read about
L<The Law of Demeter|https://en.wikipedia.org/wiki/Law_of_Demeter> for more
information. However, breaking a chain sometimes means creating a series of
mocks for each method in the chain. So we support method chains.

This I<is> a code smell. Method chains are fragile. Instead of this:

    my $office = $customer->region->sales_rep->office;

Consider this:

    # in the Customer class
    sub regional_office ($self) {
        return $self->region->sales_rep->office;
    }

And then you can just call:

    my $office = $customer->regional_office;

If the office is then moved directly to the region instead of the
salesperson, you can change that method to:

    sub regional_office ($self) {
        return $self->region->office;
    }

And your code doesn't break instead of hunting down all of the offending
method chains. (Of course, you would do this in all the places where you
need to break those chains).

That being said, it's often more work than you have time for, so this module
provides method chains. Sadly, it's again the difference between theory and
practice.

=head1 SEE ALSO

=over 4

=item * L<Test::MockObject>

I used this years ago when chromatic first wrote it for the company we worked
at. I've used it off and on over the years and I I<never> remember its
interace.

=item * L<Mock::Quick>

This one is actually pretty good, but still does a bit more than I want, and
doesn't support method chains.

=item * L<Test2::Tools::Mock>

This is the successor to L<Mock::Quick> and is included with L<Test2>. If you
have L<Test2> installed, you don't need to install another dependency.

=item * L<Test::MockModule>

Another useful module whose interface I find cumbersome, but it uses a completely
different approach from this module.

=item * L<Test::Mock::Apache2>

This was missing some methods I needed and is what finally led me to write
this module.

=back
