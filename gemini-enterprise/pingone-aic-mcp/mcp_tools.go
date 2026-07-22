package main

import (
	"context"
	"fmt"
	"log"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// registerAicMcpTools adds all AIC provisioning MCP tools to the server.
func registerAicMcpTools(s *server.MCPServer) {
	s.AddTool(provisionUserTool())
	s.AddTool(deprovisionUserTool())
	s.AddTool(updateUserStatusTool())
	s.AddTool(listUsersTool())
}

func provisionUserTool() (mcp.Tool, server.ToolHandlerFunc) {
	tool := mcp.NewTool("provision_user",
		mcp.WithDescription("Create a new user account in PingOne AIC (ForgeRock Identity Cloud). Returns the new user's internal ID."),
		mcp.WithString("username",
			mcp.Required(),
			mcp.Description("Unique username for the new account (e.g. alice.smith)."),
		),
		mcp.WithString("email",
			mcp.Required(),
			mcp.Description("Email address for the new account (e.g. alice@example.com)."),
		),
		mcp.WithString("first_name",
			mcp.Description("User's given name."),
		),
		mcp.WithString("last_name",
			mcp.Description("User's family name / surname."),
		),
		mcp.WithString("password",
			mcp.Required(),
			mcp.Description("Initial password for the account. Must meet AIC complexity requirements."),
		),
	)
	handler := func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		username, err := req.RequireString("username")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		email, err := req.RequireString("email")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		password, err := req.RequireString("password")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		firstName := req.GetString("first_name", "")
		lastName := req.GetString("last_name", "")

		log.Printf("tool=provision_user username=%s email=%s", username, email)
		result, err := CreateAicUser(username, email, firstName, lastName, password)
		if err != nil {
			log.Printf("tool=provision_user error: %v", err)
			return mcp.NewToolResultError(fmt.Sprintf("AIC error: %v", err)), nil
		}
		log.Printf("tool=provision_user success: %s", result)
		return mcp.NewToolResultText(result), nil
	}
	return tool, handler
}

func deprovisionUserTool() (mcp.Tool, server.ToolHandlerFunc) {
	tool := mcp.NewTool("deprovision_user",
		mcp.WithDescription("Permanently delete a user account from PingOne AIC by their email address."),
		mcp.WithString("email",
			mcp.Required(),
			mcp.Description("Email address of the user to delete."),
		),
	)
	handler := func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		email, err := req.RequireString("email")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		log.Printf("tool=deprovision_user email=%s", email)
		result, err := DeleteAicUser(email)
		if err != nil {
			log.Printf("tool=deprovision_user error: %v", err)
			return mcp.NewToolResultError(fmt.Sprintf("AIC error: %v", err)), nil
		}
		log.Printf("tool=deprovision_user success: %s", result)
		return mcp.NewToolResultText(result), nil
	}
	return tool, handler
}

func updateUserStatusTool() (mcp.Tool, server.ToolHandlerFunc) {
	tool := mcp.NewTool("update_user_status",
		mcp.WithDescription("Enable or disable a user account in PingOne AIC."),
		mcp.WithString("email",
			mcp.Required(),
			mcp.Description("Email address of the user to update."),
		),
		mcp.WithBoolean("enabled",
			mcp.Required(),
			mcp.Description("Set to true to activate the account, false to deactivate it."),
		),
	)
	handler := func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		email, err := req.RequireString("email")
		if err != nil {
			return mcp.NewToolResultError(err.Error()), nil
		}
		enabled := req.GetBool("enabled", true)
		log.Printf("tool=update_user_status email=%s enabled=%v", email, enabled)
		result, err := UpdateAicUserStatus(email, enabled)
		if err != nil {
			log.Printf("tool=update_user_status error: %v", err)
			return mcp.NewToolResultError(fmt.Sprintf("AIC error: %v", err)), nil
		}
		log.Printf("tool=update_user_status success: %s", result)
		return mcp.NewToolResultText(result), nil
	}
	return tool, handler
}

func listUsersTool() (mcp.Tool, server.ToolHandlerFunc) {
	tool := mcp.NewTool("list_users",
		mcp.WithDescription("List or search user accounts in PingOne AIC. Returns id, username, email, name for each matching user."),
		mcp.WithString("filter",
			mcp.Description("Optional OpenIDM query filter (e.g. 'mail sw \"alice\"'). Leave empty to list all users."),
		),
	)
	handler := func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		filter := req.GetString("filter", "")
		log.Printf("tool=list_users filter=%q", filter)
		result, err := ListAicUsers(filter)
		if err != nil {
			log.Printf("tool=list_users error: %v", err)
			return mcp.NewToolResultError(fmt.Sprintf("AIC error: %v", err)), nil
		}
		return mcp.NewToolResultText(result), nil
	}
	return tool, handler
}
