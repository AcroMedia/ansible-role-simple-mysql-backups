# ansible-role-simple-mysql-backups
![.github/workflows/molecule.yml](https://github.com/AcroMedia/ansible-role-simple-mysql-backups/workflows/.github/workflows/molecule.yml/badge.svg)

Back up MySQL databases according to a schedule, and prune the backups according to a retention policy

## Requirements

Root should be able to run mysql without being prompted for a password. Modern mariadb does this by default. The traditional method if you don't have that option is to place credentials at /root/.my.cnf with 0600 mode.

## Example playbook
```yaml
# requirements.yml
---
- name: acromedia.simple-mysql-backups
  src: https://github.com/AcroMedia/ansible-role-simple-mysql-backups
  version: origin/master
```

```yaml
# group_vars/all.yml
---
simple_mysql_backups_keep_last_hourly: 1
simple_mysql_backups_keep_last_daily: 6
simple_mysql_backups_keep_last_weekly: 3
simple_mysql_backups_keep_last_monthly: 11
```

```yaml
# playbook.yml
---
- hosts: mysql-servers
  gather_facts: true
  become: true
  roles:
    - name: Configure simple mysql backups
      role: acromedia.simple-mysql-backups
```

## Playbook variables

* #### simple_mysql_backups_space_abort_threshold
  - In percent. Default: `90`
  - To avoid filling up the volume, the script will stop and throw an error if this disk usage level is reached before or between backup operations.
  - Adjust to what makes sense for your own environment

Before a database is backed up, old backups are examined to see if they can be pruned (removed), according to these retention policy variables:


* #### simple_mysql_backups_keep_last_minimum
  - Default: 7
  - If there are only this many (or fewer) backups for a given database, pruning will not happen at all. This is a safety mechanism to keep backups from aging out of existence. The assumption is that a very old backup is more useful than none at all.

* #### simple_mysql_backups_keep_last_hourly
  - Default: 1
  - Designed for those that need to pull multiple backups throughout the day. If there are more than this many backups that exist within the last 24 hour period (of the script running), the surplus backups will be removed.

* #### simple_mysql_backups_keep_last_daily
  - Default: 6
  - A backup will be kept for each of the past `simple_mysql_backups_keep_last_daily` days.

* #### simple_mysql_backups_keep_last_weekly
  - Default: 3
  - A backup that is older than `simple_mysql_backups_keep_last_daily` will be kept from each of the previous `simple_mysql_backups_keep_last_weekly` weeks.

* #### simple_mysql_backups_keep_last_monthly
  - Default: 11
  - A backup that is older than `simple_mysql_backups_keep_last_weekly` will be kept from each of the previous `simple_mysql_backups_keep_last_monthly` months.

* #### **WARNING!!!**
 - You *MUST* set all the `...keep_last_xxx` variables to at least `1` in order for a backup to age through that retention window.

   If you set any of the above variables to zero, you will be instructing the prune script not to keep any backups for that window.

   If no backups exist in a window, then none will ever age beyond that window.

   **Example**

   If you only wanted to keep the last 5 days worth of backups, and delete everything else, you would set:
  ```yaml
  simple_mysql_backups_keep_last_hourly: 1
  simple_mysql_backups_keep_last_daily: 5
  simple_mysql_backups_keep_last_weekly: 0      # All backups older than 5 days will be deleted.
  simple_mysql_backups_keep_last_monthly: 9999  # Has no effect, since weekly is 0.
  ````
  However, if you mistakenly set "hourly" to zero, thinking you only care about daily, then you will find yourself with no backups:
  ```yaml
  simple_mysql_backups_keep_last_hourly: 0    # Oops! All backups will be pruned.
  simple_mysql_backups_keep_last_daily: 6     # Has no effect, since hourly is 0, and there are no hourly backups to age into daily.
  simple_mysql_backups_keep_last_weekly: 3    # Has no effect, since there are no daily backups to age into weekly.
  simple_mysql_backups_keep_last_monthly: 11  # Has no effect, since there are no weekly backups to age into monthly.
  ````

* #### simple_mysql_backups_cron_minute
  - default: `45`

* #### simple_mysql_backups_cron_hour
  - default: `4`

* #### simple_mysql_backups_cron_day
  - default: `'*'`

* #### simple_mysql_backups_cron_user
  - default: `root`

* #### simple_mysql_backups_cron_state
  - default: `present`

* #### simple_mysql_backups_skip_db_pattern
  - Default: `'^information_schema$|^performance_schema$|^sys$'`
  - Specify the list of databases you want to be excluded from being backed up
  - This expression is fed directly to `grep -E`. Treat it accordingly.

* #### simple_mysql_backups_ignore_empty_db_pattern
  - If a database is empty, it technically counts as an error, since the script wasn't able to back up the DB.
  - The default (`'.*'`) is to ignore warnings about all empty databases, since in most cases, these are not a concern.
  - The expression is fed to `grep -E`, so treat it accordingly
  - Examples:
    - Ignore all empty databases: `'.*'`
    - Warn about any empty database: `''`
    - Ignore warnings about a specific database: `'^my_db_name$'`
    - Ignore warnings about two specific databases: `'^my_db_name$|^my_other_db$'`


## Troubleshooting

```
mysqldump: Error 1412: Table definition has changed, please retry transaction when dumping table `XXXXXXXXXXXX` at row: 0
WARNING: Backup of database 'XXXXXXXX' reported errors.
```
The backup script calls mysqldump with `--single-transaction` and `--quick` options, which lets dumps be taken while a given database is still being used.

If **any** other process issues an `ALTER`, `DROP`, `RENAME`, or `TRUNCATE` on a given database's table while that database is being backed up, the above error will occur.

In a real-world example, if a Drupal site's cron trigger is set to run every 15 minutes, and the Simple XML Sitemap module is set to regenerate the sitemap on every cron run (which in fact does a 'truncate table' under the hood), the backup would only succeed if it did not cross paths (time-wise) with Drupal cron runs.
