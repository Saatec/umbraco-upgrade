---
description: >-
  This document covers specific upgrade steps if a version requires them. Most
  versions do not require specific upgrade steps and you will be able to upgrade
  directly from your current version.
---

# Version Specific Upgrades

## Version Specific Upgrades

Use the information below to learn about any potential breaking changes and common pitfalls when upgrading your Umbraco CMS project.

If any specific steps are involved with upgrading to a specific version they will be listed below.

Use the [general upgrade guide](../) to complete the upgrade of your project.

### Breaking changes

<details>

<summary>Umbraco 16</summary>

**TinyMCE is removed**

In Umbraco 15, two property editors were available for a rich text editor: TinyMCE and TipTap.

With Umbraco 16, only TipTap is available as an option out of the box. TinyMCE's [change of license](https://github.com/tinymce/tinymce/issues/9453#issuecomment-2327646149) precludes us from shipping it with the MIT-licensed Umbraco CMS.

When upgrading to Umbraco 16, any data types using TinyMCE will be migrated to use TipTap.

To continue to use TinyMCE, a third-party package must be installed prior to the upgrade. This will disable the migration and allow you to continue with TinyMCE.

**Package migrations are asynchronous**

Umbraco 16 adds support for asynchronous migrations and part of this work involved creating a new base class for package migrations. This leads to a source-compatible but binary-incompatible breaking change. In practice, this means that package code using migrations and calling base class helper methods such as `TableExists` can be recompiled without change. But if built against 15 and run on 16, a "method missing" exception will be thrown. For more details on the feature and the changes implemented, see the [PR](https://github.com/umbraco/Umbraco-CMS/pull/17057).

**Examine is now registered via a composer**

[A new abstraction and implementation for search](https://github.com/umbraco/Umbraco.Cms.Search) is being worked on in an external package. To support this, a method has been implemented to disable the default Examine-based search in Umbraco. This has required moving the Examine component registration to a composer.

There is no effect on the default search experience in Umbraco, but it may affect search customizations. As Examine is now registered in a composer, any custom code registered the same way is not guaranteed to run after the core setup. You should ensure to use a `[ComposeAfter(typeof(Umbraco.Cms.Infrastructure.Examine.AddExamineComposer))]` attribute to make sure custom code runs after Umbraco's default setup of Examine.

Read more in the article on [custom indexing](../../../../reference/searching/examine/indexing.md) and see [PR #18988](https://github.com/umbraco/Umbraco-CMS/pull/18988) for reference.

**Updated dependencies**

As is usual for a major upgrade, the dependencies Umbraco takes have been updated to their latest, compatible versions. This had little impact on the code of Umbraco itself, so we don't expect this to affect upgraded customer projects.

The specific dependency updates made for Umbraco 16 can be found in these PRs: for [server-side](https://github.com/umbraco/Umbraco-CMS/pull/19117) and [client-side](https://github.com/umbraco/Umbraco-CMS/pull/19121) libraries.
