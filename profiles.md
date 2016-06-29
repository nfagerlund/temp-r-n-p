---
title: "Designing advanced profiles"
---



Now that you know what to watch for when designing profiles, here's a Jenkins profile that has encountered real infrastructure and has the battle scars to prove it. This is a slightly modified version of what we actually use to manage Jenkins instances at Puppet.

After the code, we'll point out some of the less obvious choices it makes, and discuss why you might follow our lead or do things differently.

``` puppet
# /etc/puppetlabs/code/environments/production/site/profile/manifests/jenkins/master.pp
# Class: profile::jenkins::master
#
# Install a Jenkins master that meets Puppet's internal needs.
#
class profile::jenkins::master (
  Boolean                     $backups_enabled = false,
  Boolean                     $manage_plugins = false,
  Boolean                     $ssl = false,
  Optional[String[1]]         $site_alias = undef,
  Variant[String[1], Boolean] $direct_download = 'http://pkg.jenkins-ci.org/debian-stable/binary/jenkins_1.642.2_all.deb',
  Data                        $jenkins_logs_to_syslog = undef,
  Boolean                     $install_jenkins_java = true,
) {

  # Deploy the SSL certificate/chain/key for sites on this domain.
  include profile::ssl::delivery_wildcard

  # Some default values that vary by OS:
  include profile::jenkins::params
  $jenkins_owner          = $profile::jenkins::params::jenkins_owner
  $jenkins_group          = $profile::jenkins::params::jenkins_group
  $master_config_dir      = $profile::jenkins::params::master_config_dir

  if $manage_plugins {
    # About 40 jenkins::plugin resources:
    include profile::jenkins::master::plugins
  }

  motd::register { 'Jenkins CI master (profile::jenkins::master)': }

  # This adds the site_alias to the message of the day for convenience when
  # logging into a server via FQDN. Because of the way motd::register works, we
  # need a sort of funny formatting to put it at the end (order => 25) and to
  # list a class so there isn't a random "--" at the end of the message.
  if $site_alias {
    motd::register { 'jenkins-site-alias':
      content => @("END"),
                 profile::jenkins::master::proxy

                 Jenkins site alias: ${site_alias}
                 |-END
      order   => 25,
    }
  }

  # This is a "private" profile that sets up an Nginx proxy -- it's only ever
  # declared in this class, and it would work identically pasted inline.
  # But since it's long, this class reads more cleanly with it separated out.
  class { 'profile::jenkins::master::proxy':
    site_alias  => $site_alias,
    require_ssl => $ssl,
  }

  # Sensitive info (like SSH keys) isn't checked into version control like the
  # rest of our modules; instead, it's served from a custom mount point on a
  # designated server.
  $secure_server = lookup('puppetlabs::ssl::secure_server')

  # Dependencies:
  #   - Pull in apt if we're on Debian.
  #   - Pull in the 'git' package, used by Jenkins for Git polling.
  #   - Manage the 'run' directory (fix for busted Jenkins packaging).
  if $::osfamily == 'Debian' { include apt }

  package { 'git':
    ensure => present,
  }

  file { '/var/run/jenkins': ensure => 'directory' }

  # Because our account::user class manages the '${master_config_dir}' directory
  # as the 'jenkins' user's homedir (as it should), we need to manage
  # `${master_config_dir}/plugins` here to prevent the upstream
  # jenkinsci-jenkins module from trying to manage the homedir as the config
  # dir. For more info, see the upstream module's `manifests/plugin.pp`
  # manifest.
  file { "${master_config_dir}/plugins":
    ensure  => directory,
    owner   => $jenkins_owner,
    group   => $jenkins_group,
    mode    => '0755',
    require => [Group[$jenkins_group], User[$jenkins_owner]],
  }

  Account::User <| tag == 'jenkins' |>

  class { 'jenkins':
    lts                => true,
    repo               => true,
    direct_download    => $direct_download,
    version            => 'latest',
    service_enable     => true,
    service_ensure     => running,
    configure_firewall => false,
    install_java       => $install_jenkins_java,
    manage_user        => false,
    manage_group       => false,
    manage_datadirs    => false,
  }

  # When not using the jenkins module's java version, install java8.
  unless $install_jenkins_java  { include profile::jenkins::usage::java8 }

  # Manage the heap size on the master, in MB.
  if($::memorysize_mb =~ Number and $::memorysize_mb > 8192)
  {
    # anything over 8GB we should keep max 4GB for OS and others
    $heap = sprintf('%.0f', $::memorysize_mb - 4096)
  } else {
    # This is calculated as 50% of the total memory.
    $heap = sprintf('%.0f', $::memorysize_mb * 0.5)
  }
  # Set java params, like heap min and max sizes. See
  # https://wiki.jenkins-ci.org/display/JENKINS/Features+controlled+by+system+properties
  jenkins::sysconfig { 'JAVA_ARGS':
    value => "-Xms${heap}m -Xmx${heap}m -Djava.awt.headless=true -XX:+UseConcMarkSweepGC -XX:+CMSClassUnloadingEnabled -Dhudson.model.DirectoryBrowserSupport.CSP=\\\"default-src 'self'; img-src 'self'; style-src 'self';\\\"",
  }

  # (QENG-3512) Forward jenkins master logs to syslog
  # When set to facility.level the jenkins_log will use that value instead of a
  # separate log file eg. daemon.info
  if $jenkins_logs_to_syslog {
    jenkins::sysconfig { 'JENKINS_LOG':
      value => "$jenkins_logs_to_syslog",
    }
  }

  # Deploy the SSH keys that Jenkins needs to manage its builder machines and
  # access Git repos.
  file { "${master_config_dir}/.ssh":
    ensure => directory,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0700',
  }

  file { "${master_config_dir}/.ssh/id_rsa":
    ensure => file,
    owner  => 'jenkins',
    group  => 'jenkins',
    mode   => '0600',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins",
  }

  file { "${master_config_dir}/.ssh/id_rsa.pub":
    ensure => file,
    owner  => 'jenkins',
    group  => 'jenkins',
    mode   => '0640',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins.pub",
  }

  # Back up Jenkins' data.
  if $backups_enabled {
    backup::job { "jenkins-data-${::hostname}":
      files => '/var/lib/jenkins'
    }
  }

  # (QENG-1829) Logrotate rules:
  # Jenkins' default logrotate config retains too much data: by default, it
  # rotates jenkins.log weekly and retains the last 52 weeks of logs.
  # Considering we almost never look at the logs, let's rotate them daily
  # and discard after 7 days to reduce disk usage.
  logrotate::job { 'jenkins':
    log     => '/var/log/jenkins/jenkins.log',
    options => [
      'daily',
      'copytruncate',
      'missingok',
      'rotate 7',
      'compress',
      'delaycompress',
      'notifempty'
    ],
  }
}
```

### Everything we said above, but moreso

Notice how much more parameter hardcoding this profile does. And it only asks for seven parameters, even though it configures a wild amount of stuff.

Also notice how aggressively it derives configuration from facts: for example, we use the `$::memorysize_mb` fact to calculate Jenkins' heap size, because if we build a Jenkins master on a beefy server, we're definitely planning to put it under heavy load. Since we know our own patterns of system provisioning, we don't have to throw our hands up and ask for config on questions like this; we can just figure it out without bothering anyone. A component module published to the Puppet Forge would never be able to get away with that, but a business-specific wrapper can save a LOT of time this way.

### Ease of refactoring matters because you WILL refactor

This profile has had some history. You can see some of that in the comments, especially the ones that reference ticket numbers.

### Different orgs care about different options

Unlike the first profile, this one doesn't include a `$jenkins_port` parameter --- we just accept the default, and then set up a reverse proxy in front of it on ports 80 and/or 443. We're more interested in whether the instance uses SSL, whether it has a site alias, whether it needs backup support, etc.

It's just like we said before: you're designing **your** interface here, so you need to know what configuration **you** care about.

### Profiles can include other profiles

For example: We know we'll need our internal SSL certificate and key to provide Jenkins over HTTPS, so we call `include profile::ssl::delivery_wildcard`.

Depending on what else this server does, that same `profile::ssl::delivery_wildcard` class might be included by the role, and by any number of other profiles. But since they'll all use the `include` function to do it, it works out fine: that profile will get its configuration from Hiera or Puppet lookup, and there will be no conflicts.

This is a really important pattern of refactoring and code re-use in the roles and profiles method: if some technology is required by multiple profiles, and if those profiles sometimes have to coexist on the same machine, you can pull it out into a separate profile and include it everywhere.

Which is why you **must** use Hiera/lookup and keep your profiles `include`-safe: that's what gives you the freedom to refactor this way.

### Sometimes we break the rules

Except: notice that we're using one non-`include`-safe profile class here.

``` puppet
  class { 'profile::jenkins::master::proxy':
    site_alias  => $site_alias,
    require_ssl => $ssl,
  }
```

This is a resource-like class declaration on a profile class, which is a huge no-no. If we were to include that profile in a role or another profile, there's a very good chance it would blow up and put us in duplicate declaration hell.

Why did the authors do this? Because that's a "private" profile. It will _never_ be included anywhere else, because it's nothing but an implementation detail of the `profile::jenkins::master` class --- it piggybacks on the main profile's configuration data, and it has no meaning outside the main profile. It would work just as well if we pasted its entire contents inline. But since it's a large amount of Puppet code that does exactly one thing, we decided to shove it into its own class to make the main profile cleaner and more readable.

We're breaking a rule here, but we're doing it in service of readability (and thus maintainability). Also, because it has a very tiny interface, it even makes refactoring easier: `profile::jenkins::master::proxy` used to manage an Apache reverse proxy, but about a month before we copied this example, it was rewritten to manage an Nginx proxy instead. This resulted in almost no changes to the main profile. So while you have to read more files to see how a Jenkins master is really configured, we ultimately decided the benefits were worth the cost.

The takeaway here is that you should know the rules and follow them, but you also have to understand why they exist, because there are going to be times where you can make life a lot easier by breaking a few.

(But then again: How can we, as readers, know that sub-profile is private? There's no built-in way to ensure that, so you have to make sure it's documented. And in some orgs, you might decide that's not worth it, and the predictability of strict `include`-safety is worth the hit to readability. Everything is a trade-off.)

### Profiles can manage a _lot_ of stuff surrounding their main technology

Our first example just declared classes, but this one adds a huge amount of one-off resources! There are some `motd::register` resources for user-friendly SSH sessions, some `file` resources for SSH keys, some `jenkins::sysconfig` resources, a `backup::job`, a `logrotate::job`, etc.

This is exactly why profiles are useful. If everything was just a component class, you could probably assemble them some other way and assign them to nodes, but component module authors can't anticipate all of your needs, and you'll almost always need to assemble some extra pieces to _completely_ configure a service.

### Sometimes there's some opaque action at a distance `¯\_(ツ)_/¯`

Most of this profile's configuration data is well-behaved, arriving via unique class parameters. But alas, there's also a bit of indirect action:

* We call `lookup()` on some foreign keys like `puppetlabs::ssl::secure_server`, which entangles our code and makes refactoring harder. If we ever rewrite that class, we'll also need to go find all the other profiles that reach into its data and make sure they still work.

    But because that data is useful in so many places, we're willing to pay that cost to ensure it's only managed in one place. We make sure that class's entanglement is well-documented, so that anyone messing with it will know they have to follow-up _very carefully._
* To manage Jenkins' user account, we use a resource collector: `Account::User <| tag == 'jenkins' |>`. This takes advantage of some other code that's not directly related to this class: every server in our infrastructure is assigned a `profile::server` class, which in turn includes `profile::operations`, which declares a class called `virtual::users`, which has a lot of virtual resources to flexibly manage large groups of users who need access to different kinds of machines.

    This is _really_ opaque, but it's also incredibly useful, mostly because we're an engineering-heavy software shop where a lot of non-ops users need ops-like access to some limited number of machines. We've found that keeping user accounts in Puppet code in a well-managed Git repo is one of the less painful ways to manage all that. So we pay the cost, which is that everyone in ops has to know a: where these user accounts come from, and b: that all new servers need the `profile::server` class.

The theme here is trade-offs. We were faced with a few imperfect ways to approach a problem, so we chose what worked best for us and did whatever we could to offset its disadvantages. You'll do the same.

### Avoid premature optimizations

Like the `java` class in the first example, here's something we didn't pull out into its own profile:

``` puppet
  package { 'git':
    ensure => present,
  }
```

There are probably a LOT of technology stacks that require Git, so I could easily imagine Git having its own profile. But:

* So far, we haven't built any servers where Jenkins has to co-exist with some other service that needs Git. And we don't really expect to build any. So there's no need to push it off into an `include`-safe class yet.
* This is a really small amount of configuration. We're not templating any config files, starting any services, or anything. Keeping this little package resource nearby is a nice win for readability, because it would be pointlessly annoying to go open another file and just find a little three-liner.

So as long as you can get away with it, go ahead and put semi-shared resources like this into specialized profiles, because it makes for more readable code. You might never have to move them out.

Conversely, notice that we have a `profile::jenkins::params` class that does nothing but set some variables with conditional logic. You can easily imagine this profile being more readable if we moved that logic inside it.

But as it happens, we have a big pile of other profiles for managing the builder nodes that our Jenkins system relies on, and they need some of the same default data that our Jenkins masters need. So at some point, we decided to move that data into a shared class, because the cost of reading separated code became a lot less than the cost of keeping multiple copies of the code up to date. I haven't read the entire Git history, but my guess is that we waited to optimize that until we had to.

As always, the take-away is that everything is a trade-off and you have to keep your eye on what's important to your org.

