using System;
using NPoco;
using Umbraco.Core;
using Umbraco.Core.Composing;
using Umbraco.Core.Logging;
using Umbraco.Core.Migrations;
using Umbraco.Core.Migrations.Upgrade;
using Umbraco.Core.Persistence.DatabaseAnnotations;
using Umbraco.Core.Scoping;
using Umbraco.Core.Services;

namespace SampleSite.Data
{
    // Synthetic fixture: registers the component that runs the migration plan.
    public class FeedbackComposer : ComponentComposer<FeedbackComponent>
    {
    }

    public class FeedbackComponent : IComponent
    {
        private readonly IScopeProvider _scopeProvider;
        private readonly IMigrationBuilder _migrationBuilder;
        private readonly IKeyValueService _keyValueService;
        private readonly ILogger _logger;

        public FeedbackComponent(IScopeProvider scopeProvider, IMigrationBuilder migrationBuilder, IKeyValueService keyValueService, ILogger logger)
        {
            _scopeProvider = scopeProvider;
            _migrationBuilder = migrationBuilder;
            _keyValueService = keyValueService;
            _logger = logger;
        }

        public void Initialize()
        {
            var plan = new MigrationPlan("SampleFeedback");
            plan.From(string.Empty).To<AddFeedbackTable>("feedback-table-v1");
            new Upgrader(plan).Execute(_scopeProvider, _migrationBuilder, _keyValueService, _logger);
        }

        public void Terminate()
        {
        }
    }

    public class AddFeedbackTable : MigrationBase
    {
        public AddFeedbackTable(IMigrationContext context) : base(context)
        {
        }

        public override void Migrate()
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
            public string Comment { get; set; }

            [Column("CreatedUtc")]
            public DateTime CreatedUtc { get; set; }
        }
    }
}
