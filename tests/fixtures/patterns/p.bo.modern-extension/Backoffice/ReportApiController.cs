using Microsoft.AspNetCore.Mvc;
using Umbraco.Cms.Api.Management.Controllers;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: an API for a backoffice extension.
[Route("/umbraco/sample/api/v1/report")]
public class ReportApiController : ManagementApiControllerBase
{
    [HttpGet]
    public IActionResult Get() => Ok("ok");
}
