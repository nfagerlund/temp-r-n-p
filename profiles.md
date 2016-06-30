---
title: "Designing advanced profiles"
---

[include]: TODO
[resource-like]: TODO
[virtual resources]: TODO
[resource collector]: TODO
[custom mount point]: TODO
[puppetlabs/motd]: TODO
[jfryman/nginx]: TODO

Now that you understand how the roles and profiles method works, we can focus more deeply on writing profiles.

Our example profile on the previous page was very simple, and didn't realistically show how to manage a complex service. On this page, we'll repeatedly refactor that example to handle real-world concerns. The final result is --- with only minor differences --- the Jenkins profile we use in production here at Puppet.

Along the way, we'll explain our choices and point out some of the common trade-offs you'll encounter as you design your own profiles.

## Reminders

### The initial code

Here's the Jenkins profile we started with:

``` puppet
# /etc/puppetlabs/code/environments/production/site/profile/manifests/jenkins/master.pp
class profile::jenkins::master (
  String $jenkins_port = '9091',
  String $java_dist    = 'jdk',
  String $java_version = 'latest',
) {

  class { 'jenkins':
    configure_firewall => true,
    install_java       => false,
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }

  class { 'java':
    distribution => $java_dist,
    version      => $java_version,
    before       => Class['jenkins'],
  }
}
```

### The rules

...and here are the rules for writing profile classes:

1. Make profiles work safely with [the `include` function][include] --- don't use [resource-like declarations][resource-like] on them.
2. Profiles can `include` other profiles.
3. Profiles own _all_ the class parameters for their component classes. If the profile omits one, that means we definitely want the default value; the component class shouldn't grab a value from Hiera data. If you need to set a class parameter that was omitted previously, refactor the profile.
4. There are three ways a profile can get the information it needs to configure component classes:
    * If your business will always use the same value for a given parameter, **hardcode it.**
    * If you can't hardcode it, try to **compute it** based on information you already have.
    * Finally, if you can't compute it, **look it up** in your data. To reduce lookups, try to identify cases where multiple parameters can be derived from the answer to a single question.

## First refactor: split out Java

In addition to Jenkins masters, we also want to manage our Jenkins agent nodes. We won't cover the profile that does that, but the first issue we encounter is that they also need Java.

We could copy and paste the code that manages Java: it's fairly small, so maintaining multiple copies might not be too burdensome. But instead, we decided to break Java out into a separate profile. That lets us manage it in only one place, then include the Java profile in both the agent and master profiles.

> **Note:** This is a common trade-off. Keeping a chunk of code in only one place (often called the DRY --- "don't repeat yourself" --- principle) makes code more maintainable and less vulnerable to rot, but the cost is that your individual profile classes become less readable; you must view more files to see what a profile actually does.
>
> To reduce that readability cost, try to break code out in units that make inherent sense. In this case, the Java profile's job is simple enough to guess by its name --- your colleagues don't have to read its code to know that it manages Java 8.

First, we must decide how much configuration we actually need for Java on Jenkins machines. After looking at our past usage, we realized that we only use two options: either we install Oracle's Java 8 distribution, or we default to OpenJDK 7. And the Jenkins module can manage the latter! This means we can:

* Make our new Java profile really simple: hardcode Java 8 and take no configuration.
* Replace the two Java parameters from `profile::jenkins::master` with one boolean parameter asking whether to let Jenkins handle it.

> **Note:** Rule 4 in action: we can reduce our profile's configuration surface by combining multiple questions into one.

Here's the new parameter list:

``` puppet
  String  $jenkins_port = '9091',
  Boolean $install_jenkins_java = true,
```

And here's how we choose which Java to use:

``` puppet
  class { 'jenkins':
    configure_firewall => true,
    install_java       => $install_jenkins_java, # <--- Here!
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }

  # When not using the jenkins module's java version, install java8.
  unless $install_jenkins_java  { include profile::jenkins::usage::java8 }
```

And our new Java profile:

``` puppet
# Class: profile::jenkins::usage::java8
# Sets up java8 for Jenkins on Debian
#
class profile::jenkins::usage::java8 {
  motd::register { 'Java usage profile (profile::jenkins::usage::java8)': }

  # OpenJDK 7 is already managed by the Jenkins module.
  # ::jenkins::install_java or ::jenkins::slave::install_java should be false to use this profile
  # this can be set through the class parameter $intall_jenkins_java
  case $::osfamily {
    'debian': {
      class { '::java':
        distribution => 'oracle-jdk8',
        version      => '8u92',
      }

      package { 'tzdata-java':
        ensure => latest,
      }
    }
    default: {
      notify { "profile::jenkins::usage::java8 cannot set up JDK on ${::osfamily}": }
    }
  }
}
```

## Second refactor: manage the heap

We found that we needed to manage the Java heap size for the Jenkins app --- production servers didn't have enough memory for heavy use.

The Jenkins module has a `jenkins::sysconfig` defined type for managing this kind of thing, so we'll use that:

``` puppet
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
```

> **Note:** Rule 4 again: We couldn't hardcode this, because we have some smaller Jenkins masters that don't need the extra muscle. But since our production masters are always on beefier boxes, we can calculate the heap based on the machine's memory size. This lets us avoid extra configuration.

## Third refactor: pin the version

We dislike surprise upgrades, so we'll pin Jenkins to a specific version. (We decided to do this with a direct package URL instead of managing Jenkins in our package repositories. Your org might choose to do it differently.)

First, we add a parameter, so we can upgrade Jenkins earlier on specific machines:

``` puppet
  Variant[String[1], Boolean] $direct_download = 'http://pkg.jenkins-ci.org/debian-stable/binary/jenkins_1.642.2_all.deb',
```

Then, we set the necessary parameters in the Jenkins class:

``` puppet
  class { 'jenkins':
    lts                => true,             <-- here
    repo               => true,             <-- here
    direct_download    => $direct_download, <-- here
    version            => 'latest',         <-- here
    service_enable     => true,
    service_ensure     => running,
    configure_firewall => true,
    install_java       => $install_jenkins_java,
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }
```

This seemed like a good time to make sure we're explicitly managing the Jenkins _service,_ so we did that as well.

## Fourth refactor: change how we manage the user account

We manage a lot of user accounts in our infrastructure, so we get a lot of benefit from handling them in a unified way. One of the things `profile::server` does is pull in a class called `virtual::users` --- this has a lot of [virtual resources][], which we selectively realize depending on who needs to log into a given machine. This has a cost (it's action at a distance, and you need to view more files to see which users are actually being enabled for a given profile), but we decided the benefit was worth it (all user accounts are written in one or two files, so it's extremely easy to see all the users that might exist).

So we'll change the Jenkins profile to work the same way, and manage the `jenkins` user alongside the rest of our user accounts. While we're doing that, we'll also manage a few directories that can be problematic depending on how Jenkins is packaged.

Some values we need are used by Jenkins agents as well as masters, so we're going to store them in a params class. This is kind of a heavyweight solution, so you should wait until it provides real value before using it; in our case, there were a lot of agent-related profiles (not shown here) that made a params class worthwhile.

> **Note:** Like we said before, "DRY" is in tension with "keep it readable." You have to find the balance that works for you.

``` puppet
  # We rely on virtual resources that are ultimately declared by profile::server.
  include profile::server

  # Some default values that vary by OS:
  include profile::jenkins::params
  $jenkins_owner          = $profile::jenkins::params::jenkins_owner
  $jenkins_group          = $profile::jenkins::params::jenkins_group
  $master_config_dir      = $profile::jenkins::params::master_config_dir

  file { '/var/run/jenkins': ensure => 'directory' }

  # Because our account::user class manages the '${master_config_dir}' directory
  # as the 'jenkins' user's homedir (as it should), we need to manage
  # `${master_config_dir}/plugins` here to prevent the upstream
  # rtyler-jenkins module from trying to manage the homedir as the config
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
    lts                => true,             <-- here
    repo               => true,             <-- here
    direct_download    => $direct_download, <-- here
    version            => 'latest',         <-- here
    service_enable     => true,
    service_ensure     => running,
    configure_firewall => true,
    install_java       => $install_jenkins_java,
    manage_user        => false,
    manage_group       => false,
    manage_datadirs    => false,
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }
```

Three things to notice in the code above:

* We use an `Account::User` [resource collector][] to realize the Jenkins user. This relies on `profile::server` being declared.
* We set the Jenkins class's `manage_user`, `manage_group`, and `manage_datadirs` parameters to false.
* We're now explicitly managing the plugins directory and the run directory.


## Fifth refactor: manage more of Jenkins' dependencies

* We use Git for source control, so Jenkins is always going to need access to Git.
* It needs some SSH keys to access some private Git repos, as well as to run commands on Jenkins agent nodes.
* We also have a standard list of Jenkins plugins we use, so we might as well manage those as well.

Git is pretty easy:

``` puppet
  package { 'git':
    ensure => present,
  }
```

SSH keys are less easy. We can't check these into our control repo with the rest of our Puppet code, so we put them in a [custom mount point][] on one specific Puppet server.

Since this server is different from our normal Puppet servers, we made a rule about accessing it: you must look up the hostname from data instead of hardcoding it. This lets us change it in only one place if the secure server ever moves.

``` puppet
  $secure_server = lookup('puppetlabs::ssl::secure_server')

  file { "${master_config_dir}/.ssh":
    ensure => directory,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0700',
  }

  file { "${master_config_dir}/.ssh/id_rsa":
    ensure => file,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0600',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins",
  }

  file { "${master_config_dir}/.ssh/id_rsa.pub":
    ensure => file,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0640',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins.pub",
  }
```

Plugins are also a bit sticky, because we have a few Jenkins masters where we want to manually configure plugins. So we'll put the base list in a separate profile, and use a parameter to control whether we use it.

``` puppet
class profile::jenkins::master (
  Boolean                     $manage_plugins = false,
  # ...
) {
  # ...
  if $manage_plugins {
    include profile::jenkins::master::plugins
  }
```

In the plugins profile, we can use the `jenkins::plugin` resource type provided by the Jenkins module.

``` puppet
# /etc/puppetlabs/code/environments/production/site/profile/manifests/jenkins/master/plugins.pp
class profile::jenkins::master::plugins {
  jenkins::plugin { 'audit2db':          }
  jenkins::plugin { 'credentials':       }
  jenkins::plugin { 'jquery':            }
  jenkins::plugin { 'job-import-plugin': }
  jenkins::plugin { 'ldap':              }
  jenkins::plugin { 'mailer':            }
  jenkins::plugin { 'metadata':          }
  # ... and so on.
}
```

## Sixth refactor: manage logging and backups

Backing up: usually a good idea. We have a homegrown `backup` module that provides a `backup::job` resource type, and `profile::server` takes care of its prerequisites. But we should make backups a parameter, so people don't accidentally post junk to our backup server.

``` puppet
class profile::jenkins::master (
  Boolean                     $backups_enabled = false,
  # ...
) {

  # ...

  if $backups_enabled {
    backup::job { "jenkins-data-${::hostname}":
      files => $master_config_dir,
    }
  }
}
```

Also, our teams gave us some conflicting requests for Jenkins' logs:

* Some people want it to log to syslog, like most other services.
* Others want a distinct log file so syslog doesn't get spammed, and they want the file to rotate more quickly than it does by default.

That sounds like a parameter. We'll make one called `$jenkins_logs_to_syslog` and default it to `undef`; if you set it to a standard syslog facility (like `daemon.info`), Jenkins will log there instead of its own file.

We'll use `jenkins::sysconfig` and our homegrown `logrotate::job` to do the heavy lifting:

``` puppet
class profile::jenkins::master (
  Optional[String[1]]         $jenkins_logs_to_syslog = undef,
  # ...
) {

  # ...

  if $jenkins_logs_to_syslog {
    jenkins::sysconfig { 'JENKINS_LOG':
      value => "$jenkins_logs_to_syslog",
    }
  }

  # ...

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


## Seventh refactor: use a reverse proxy to provide HTTPS

We want Jenkins' web interface to use HTTPS, which we'll accomplish with an Nginx reverse proxy. We'll also standardize the ports: the Jenkins app will always bind to its default port, and the proxy will always serve over 443 for HTTPS and 80 for HTTP.

In case we want to keep vanilla HTTP available, we'll provide an `$ssl` parameter. If set to `false` (the default), you can access Jenkins via both HTTP and HTTPS. We'll also add a `$site_alias` parameter, so the proxy can listen on a hostname other than the node's main FQDN.

``` puppet
class profile::jenkins::master (
  Boolean                     $ssl = false,
  Optional[String[1]]         $site_alias = undef,
  # ...
```

We'll set `configure_firewall => false` in the Jenkins class:

``` puppet
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
```

We need to deploy SSL certificates where Nginx can reach them. Since we serve a lot of things over HTTPS, we already had a profile for that:

``` puppet
  # Deploy the SSL certificate/chain/key for sites on this domain.
  include profile::ssl::delivery_wildcard
```

This is also a good time to add some info for the message of the day, handled by [puppetlabs/motd][]:

``` puppet
  motd::register { 'Jenkins CI master (profile::jenkins::master)': }

  if $site_alias {
    motd::register { 'jenkins-site-alias':
      content => @("END"),
                 profile::jenkins::master::proxy

                 Jenkins site alias: ${site_alias}
                 |-END
      order   => 25,
    }
  }
```

The bulk of the work will be handled by a new profile called `profile::jenkins::master::proxy`. We're omitting the code for this class to keep this page to a reasonable size; in summary, what it does is:

* Include `profile::nginx`.
* Use resource types from the [jfryman/nginx][] to set up a vhost, and to force a redirect to HTTPS if we haven't enabled vanilla HTTP.
* Set up logstash forwarding for access and error logs.
* Include `profile::fw::https` to manage firewall rules, if necessary.

Then, we declare that profile in our main profile:

``` puppet
  class { 'profile::jenkins::master::proxy':
    site_alias  => $site_alias,
    require_ssl => $ssl,
  }
```

> **Important:** We are now breaking rule 1, the most important rule of the roles and profiles method. Why?
>
> Because `profile::jenkins::master::proxy` is a "private" profile that belongs **solely** to `profile::jenkins::master`. It will never be declared by any role or any other profile.
>
> This is the only exception to rule 1: if you're separating out code _for the sole purpose of readability_ --- that is, if you could paste the private profile's contents into the main profile for the exact same effect --- you can use a resource-like declaration on the private profile. This lets you consolidate your data lookups and make the private profile's inputs more visible, while keeping the main profile a little cleaner.
>
> If you do this, you must make sure to document that the private profile is private.


## The final code

After all of this refactoring (and a few more minor adjustments), here's the final code for `profile::jenkins::master`:

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
  Optional[String[1]]         $jenkins_logs_to_syslog = undef,
  Boolean                     $install_jenkins_java = true,
) {

  # We rely on virtual resources that are ultimately declared by profile::server.
  include profile::server

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

  # Forward jenkins master logs to syslog.
  # When set to facility.level the jenkins_log will use that value instead of a
  # separate log file eg. daemon.info
  if $jenkins_logs_to_syslog {
    jenkins::sysconfig { 'JENKINS_LOG':
      value => "$jenkins_logs_to_syslog",
    }
  }

  # Deploy the SSH keys that Jenkins needs to manage its agent machines and
  # access Git repos.
  file { "${master_config_dir}/.ssh":
    ensure => directory,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0700',
  }

  file { "${master_config_dir}/.ssh/id_rsa":
    ensure => file,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0600',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins",
  }

  file { "${master_config_dir}/.ssh/id_rsa.pub":
    ensure => file,
    owner  => $jenkins_owner,
    group  => $jenkins_group,
    mode   => '0640',
    source => "puppet://${secure_server}/secure/delivery/id_rsa-jenkins.pub",
  }

  # Back up Jenkins' data.
  if $backups_enabled {
    backup::job { "jenkins-data-${::hostname}":
      files => $master_config_dir,
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

