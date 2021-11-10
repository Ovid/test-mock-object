# NAME

Test::Mock::Object - Dead-simple mocking

# VERSION

version 0.1

# SYNOPSIS

```perl
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
```

# DESCRIPTION

Mock objects can be a controversial topic, but sometimes they're very useful.
However, mock objects in Perl often come in two flavors:

- Incomplete mocks of existing modules
- Generic mocks with clumsy interfaces I can never remember

This module is my attempt to make things dead-easy. Here's a simple mock object:

```perl
my $mock = create_mock(
    package => 'Toy::Soldier',
    methods => {
        name   => 'Ovid',
        rank   => 'Private',
        serial => '123-456-789',
    }
);
```

You can figure out what that does and it's easy. However, we have a lot more.

Note, that while `$mocked->isa($package)` will return true for the name
of the package you're mocking, but the package will be blessed into a
namespace similar to `MockMeAmadeus::$compact_package`, where
`$compact_package` is the name of the blessed package, but with `::`
replaced with underscores, along with a prepended `_V$mock_number`. Thus,
mocking something into the `Foo::Bar` package would cause `ref` to return
something like `MockMeAmadeus::Foo_Bar_b1`.

If you need something more interesting for `isa`, pass in your own:

```perl
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
```

# FUNCTIONS

These functions are exportable individually or with `::all`:

```perl
use Test::Mock::Object qw(
  add_method
  create_mock
  read_only
  reset_mocked_calls
);
# same as
use Test::Mock::Object ':all';
```

## `create_mock( package => $package, methods => \%methods )`

```perl
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
```

We simply declare the package and the methods we need. If the package has not
yet been loaded, we alter `%INC` to ensure the package cannot be loaded after
this. This is a convenience if we have a module that's very hard to load.

As for the methods, if we point to a coderef, that's the method. If we point to
_anything else_, the method will return that value and you can set it to a new
value.

Arguments to `create_mock()` are:

- `package`

    The name of the package we will mock.

    Required.

- `methods`

    Key/Value pairs of methods. Keys are method names of the objects and values
    what those methods return, with one important exception.

    If the value is a subroutine reference, that reference _becomes_ the method
    for the key. If you want a method to _return_ a subroutine reference, you
    need to wrap that in another subroutine reference.

    ```perl
    method => sub { sub { ... } }
    ```

    Optional.

- `method_chains`

    (Still experimental)

    An array reference of array references. Optional.

    ```perl
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
    ```

    We have incomplete support for chains that might start
    with the same method.

## `read_only($value)`

When used with a method value, will throw a fatal error if
you try to set that value:

```perl
uri => read_only('/foo/bar')
```

## `add_method($mock_object, $method_name, $value)`

Just like the key/value pairs to `create_mock()`, this adds a getter/setter
for `$value`.  If `$value` is a code reference, it will be added directly as
the method. You can make the value read-only, if needed:

```
add_method($mock_object, 'created', read_only(DateTime->now));
```

## `reset_mocked_calls($mock_object)`

```
reset_mocked_calls($mock_object);
```

This reset the "times called" internals to 0 for every method. See ["Inside
the object"](#inside-the-object).

# Mocked Methods

## `isa`

```
if ( $r->isa('Apache2::RequestRec') ) {
    ...
}
```

Returns true if the classname passed in matches the name passed to `create_mock`

# Inside the object

The object returned encapsulates all data thoroughly. However, it's a blessed
hashref whos keys are the names of the methods, each pointing to hashref with
information about how they were called in the code. So our example above would
have this:

```perl
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
```

`times_called` is the number of times that method was called in the code
you're using it in.

`times_with_args` is the number of times that method was called
with arguments.

`times_without_args` is the number of times that method was called without
arguments.

# Unknown methods

The methods you request are the methods you will receive. Any attempt to call
unknown methods will be a fatal error.

# BEST PRACTICES

## Don't Use Mock Objects

See ["Interface Changes"](#interface-changes). However, if you're relying on sometthing you don't
control, such as an object that requires a database connection or an internet
connection, a mock might be acceptable.

## Only Mock the Methods You Use

You might be tempted to mock every single method in an interface. Don't do that.
Only mock the methods that you actually use. That way, if the code is updated to
call a method you didn't mock, your test with fail with a "Method not found"
error.

# LIMITATIONS

Be aware that while mock objects can be useful, there are several limitations
to be aware of.

## Interface Changes

In theory, objects should be open for extension, closed for modification.

In practice, we have deadlines, we make mistakes, needs evolve, whatever. If
your mock object mocks an instance of `Foo::Bar` and you install a new
version of `Foo::Bar` with a different interface, your mock may very well
hide the fact that your code is broken.

## Encapsulation Violations

Constantly you see developers do things like this:

```perl
# don't reach inside!
my $name = $object->{name};
```

And:

```
# this should be an ->isa check
if ( ref $object eq 'Toy::Soldier' ) {
    ...
}
```

Both of those will fail with `Test::Mock::Object`. This is by design to avoid
the temptation to ignore these issues. This might mean that
`Test::Mock::Object` is not suitable for your needs.

## We Changes Instances, Not Classes

Thus, if you mock an instance of a base class, subclasses won't see that (and
other instances won't see that either). Instead, you might find [Mock::Quick](https://metacpan.org/pod/Mock%3A%3AQuick)
useful. [Test::MockModule](https://metacpan.org/pod/Test%3A%3AMockModule) might also help, or if you just need to replace one
or two methods in a lexical scope, see [Sub::Override](https://metacpan.org/pod/Sub%3A%3AOverride).

# NOTES

## Memory Leak Protection

If you install [Test::LeakTrace](https://metacpan.org/pod/Test%3A%3ALeakTrace), a test in our test suite will verify that
we do not have memory leaks. I've only tested this on a couple of versions of
Perl. It's possible that some versions will leak. Please let me know if this
happens.

## Chained Methods

Method chains are often a code smell. You can read about
[The Law of Demeter](https://en.wikipedia.org/wiki/Law_of_Demeter) for more
information. However, breaking a chain sometimes means creating a series of
mocks for each method in the chain. So we support method chains.

This _is_ a code smell. Method chains are fragile. Instead of this:

```perl
my $office = $customer->region->sales_rep->office;
```

Consider this:

```perl
# in the Customer class
sub regional_office ($self) {
    return $self->region->sales_rep->office;
}
```

And then you can just call:

```perl
my $office = $customer->regional_office;
```

If the office is then moved directly to the region instead of the
salesperson, you can change that method to:

```perl
sub regional_office ($self) {
    return $self->region->office;
}
```

And your code doesn't break instead of hunting down all of the offending
method chains. (Of course, you would do this in all the places where you
need to break those chains).

That being said, it's often more work than you have time for, so this module
provides method chains. Sadly, it's again the difference between theory and
practice.

# SEE ALSO

- [Test::MockObject](https://metacpan.org/pod/Test%3A%3AMockObject)

    I used this years ago when chromatic first wrote it for the company we worked
    at. I've used it off and on over the years and I _never_ remember its
    interace.

- [Mock::Quick](https://metacpan.org/pod/Mock%3A%3AQuick)

    This one is actually pretty good, but still does a bit more than I want, and
    doesn't support method chains.

- [Test::MockModule](https://metacpan.org/pod/Test%3A%3AMockModule)

    Another useful module whose interface I find cumbersome, but it uses a completely
    different approach from this module.

- [Test::Mock::Apache2](https://metacpan.org/pod/Test%3A%3AMock%3A%3AApache2)

    This was missing some methods I needed and is what finally led me to write
    this module.

# AUTHOR

Curtis "Ovid" Poe <ovid@allaroundtheworld.fr>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2021 by Curtis "Ovid" Poe.

This is free software, licensed under:

```
The Artistic License 2.0 (GPL Compatible)
```
