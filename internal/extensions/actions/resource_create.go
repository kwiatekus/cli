package actions

import (
	"fmt"

	"github.com/kyma-project/cli.v3/internal/clierror"
	"github.com/kyma-project/cli.v3/internal/cmdcommon"
	"github.com/kyma-project/cli.v3/internal/extensions/actions/common"
	"github.com/kyma-project/cli.v3/internal/extensions/types"
	"github.com/spf13/cobra"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

type resourceCreateActionConfig struct {
	Resource map[string]interface{} `yaml:"resource"`
}

type resourceCreateAction struct {
	common.TemplateConfigurator[resourceCreateActionConfig]

	kymaConfig *cmdcommon.KymaConfig
}

func NewResourceCreate(kymaConfig *cmdcommon.KymaConfig) types.Action {
	return &resourceCreateAction{
		kymaConfig: kymaConfig,
	}
}

func (a *resourceCreateAction) Run(cmd *cobra.Command, _ []string) clierror.Error {
	u := &unstructured.Unstructured{
		Object: a.Cfg.Resource,
	}

	client, clierr := a.kymaConfig.GetKubeClientWithClierr()
	if clierr != nil {
		return clierr
	}

	err := client.RootlessDynamic().Apply(a.kymaConfig.Ctx, u)
	if err != nil {
		return clierror.Wrap(err, clierror.New("failed to create resource"))
	}

	fmt.Fprintf(cmd.OutOrStdout(), "resource %s applied\n", u.GetName())
	return nil
}
