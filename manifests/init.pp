class redmine (
  $version              = "2.0.3",
  $admin_password       = "admin",
  $database             = "redmine",
  $username             = "redmine",
  $password             = "redmine",
  $host                 = "localhost",
  $configuration_source = undef,
  $service_to_restart   = undef,
  # Redmine admin settings
  $app_title            = "Redmine",
  $host_name            = "localhost",
  $ui_theme             = "",

  $install_path     = "/var/www/redmine"
) {
  Exec {path => $path}
  $real_path= "/usr/local/lib/redmine" # Needs due to a bug in "file as directory, recurse true"
  $owner    = "www-data"
  $gem_bin  = "$(gem env gemdir)/bin"


  exec { 'Create redmine directory':
    command => "mkdir -p '${install_path}'",
    unless  => "test -d '${install_path}'",
  }

  package {"rubygems":}

  package {"rake": }

  if defined(Package["git"]) != true {
    package {"git":}
  }


  exec {"Download redmine":
    require => [Package["git"], Exec["Create redmine directory"]],
    cwd     => $install_path,
    onlyif  => "test ! -d $install_path/app",
    command => "git clone git://github.com/redmine/redmine.git .",
  }

  exec {"Choosing redmine version":
    require => Exec["Download redmine"],
    cwd     => $install_path,
    onlyif  => "test '$version' != $(git describe --exact-match --all --tags --always HEAD)",
    command => "git checkout $version",
  }

  $command_fetch_changesets = template("redmine/command_fetch_changesets.sh.erb")
  file {"Making production log writable to allow execute fetch changesets from hooks":
    require => Exec["Choosing redmine version"],
    ensure  => present,
    path    => "${install_path}/log/production.log",
    owner   => $owner,
    group   => $owner,
    mode    => 0666,
  }

  exec {"Setting redmine owner":
    require => Exec["Choosing redmine version"],
    cwd     => $install_path,
    onlyif  => "test '$owner' != $(stat --format=%U $install_path/app)",
    command => "chown --recursive $owner:$owner .",
  }

  file {"Setting up redmine database":
    require => Exec["Choosing redmine version"],
    ensure  => present,
    owner   => $owner,
    group   => $owner,
    path    => "$install_path/config/database.yml",
    content => template("redmine/database.yml.erb")
  }

  if $configuration_source {
    file {"Configuring redmine by settings file":
      require => Exec["Choosing redmine version"],
      ensure  => present,
      owner   => $owner,
      group   => $owner,
      path    => "$install_path/config/configuration.yml",
      source  => $configuration_source,
      notify  => $service_to_restart
    }
  }

  $gems_libraries = ["libmysqlclient-dev", "imagemagick", "libmagickwand-dev"]
  package {$gems_libraries:}

  $gems = ["rack", "i18n", "rails", "bundler", "mysql", "rmagick"]
  package {$gems:
    require   => [Package["rubygems"], Package[$gems_libraries]],
    provider  => "gem",
  }

#  exec {"Making bundle bin visible":
#    require   => Package[$gems],
#    command   => "ln --symbolic $gem_bin/bundle /usr/bin/bundle",
#    creates   => "/usr/bin/bundle",
#  }

  exec {"Installing needed bundles":
    require   => [Exec["Choosing redmine version"]],
    creates   => "$install_path/config/initializers/secret_token.rb",
    cwd       => $install_path,
    command   => "bundle install --without development test postgresql sqlite",
  }

  exec {"Initializing redmine":
    require   => [File["Setting up redmine database"], Exec["Installing needed bundles"], Exec["Setting redmine owner"]],
    before    => $service_to_restart,
    creates   => "$install_path/config/initializers/secret_token.rb",
    user      => $owner,
    cwd       => $install_path,
    command   => "bundle exec rake generate_secret_token db:migrate RAILS_ENV=production REDMINE_LANG=ru",
  }

  exec {"Loading defaults in redmine":
    require   => Exec["Initializing redmine"],
    onlyif    => "test 0 = $(mysql -e 'select count(*) from $database.trackers' | tail -n1)",
    cwd       => $install_path,
    command   => "bundle exec rake redmine:load_default_data RAILS_ENV=production REDMINE_LANG=ru",
  }

  file {"Preparing redmine settings":
    require => Exec["Choosing redmine version"],
    ensure  => present,
    path    => "$install_path/config/settings.mysql.sql",
    content => template("redmine/settings.mysql.sql.erb")
  }

  exec {"Applying redmine settings":
    require     => [File["Preparing redmine settings"], Exec["Loading defaults in redmine"]],
    subscribe   => File["Preparing redmine settings"],
    refreshonly => true,
    cwd         => "$install_path/config",
    command     => "mysql --default_character_set utf8 $database < settings.mysql.sql",
  }

}
