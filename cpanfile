requires qw/ Class::Load         /;
requires qw/ Data::Dump          /;
requires qw/ IPC::System::Simple /;
requires qw/ JSON::XS            /;
requires qw/ List::MoreUtils     /;
requires qw/ Params::Validate    /;
requires qw/ Role::Tiny::With    /;
requires qw/ Term::ANSIColor     /;
requires qw/ Text::Unidecode     /;
requires qw/ Try::Tiny           /;
requires qw/ YAML::Syck          /;
requires qw/ autodie             /;
requires qw/ experimental        /;

on 'test' => sub {
    requires qw/Test::Deep        0.109    /;
    requires qw/Test::MockModule  0.05     /;
};
