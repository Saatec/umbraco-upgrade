using Microsoft.AspNetCore.Mvc;
using Umbraco.Cms.Web.BackOffice.Controllers;
using Umbraco.Cms.Web.Common.Attributes;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: called by a backoffice script.
[PluginController("SampleSite")]
public class ExportApiController : UmbracoAuthorizedApiController
{
    [HttpGet]
    public IActionResult Status() => Ok("ready");
}
