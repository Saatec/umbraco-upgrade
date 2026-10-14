using NPoco;
using Umbraco.Cms.Core;
using Umbraco.Cms.Core.Events;
using Umbraco.Cms.Core.Migrations;
using Umbraco.Cms.Core.Notifications;
using Umbraco.Cms.Core.Scoping;
using Umbraco.Cms.Core.Services;
using Umbraco.Cms.Infrastructure.Migrations;
using Umbraco.Cms.Infrastructure.Migrations.Upgrade;
using Umbraco.Cms.Infrastructure.Persistence.DatabaseAnnotations;

namespace SampleSite.Web.Data;

// Synthetic fixture: runs the feedback migration plan when the application starts.
public class RunFeedbackMigration : INotificationHandler<UmbracoApplicationStartingNotification>
{
    private readonly IMigrationPlanExecutor _migrationPlanExecutor;
    private readonly ICoreScopeProvider _coreScopeProvider;
    private readonly IKeyValueService _keyValueService;
    private readonly IRuntimeState _runtimeState;

    public RunFeedbackMigration(
        ICoreScopeProvider coreScopeProvider,
        IMigrationPlanExecutor migrationPlanExecutor,
        IKeyValueService keyValueService,
        IRuntimeState runtimeState)
    {
        _migrationPlanExecutor = migrationPlanExecutor;
        _coreScopeProvider = coreScopeProvider;
        _keyValueService = keyValueService;
        _runtimeState = runtimeState;
    }

    public void Handle(UmbracoApplicationStartingNotification notification)
    {
        if (_runtimeState.Level < RuntimeLevel.Run)
        {
            return;
        }

        var plan = new MigrationPlan("SampleFeedback");
        plan.From(string.Empty).To<AddFeedbackTable>("feedback-table-v1");
        new Upgrader(plan).Execute(_migrationPlanExecutor, _coreScopeProvider, _keyValueService);
    }
}

public class AddFeedbackTable : MigrationBase
{
    public AddFeedbackTable(IMigrationContext context) : base(context)
    {
    }

    protected override void Migrate()
    {
        if (!TableExists("sampleFeedback"))
        {
            Create.Table<FeedbackSchema>().Do();
        }
    }

    [TableName("sampleFeedback")]
    [PrimaryKey("Id", AutoIncrement = true)]
    [ExplicitColumns]
    public class FeedbackSchema
    {
        [PrimaryKeyColumn(AutoIncrement = true, IdentitySeed = 1)]
        [Column("Id")]
        public int Id { get; set; }

        [Column("Comment")]
        public required string Comment { get; set; }
    }
}
